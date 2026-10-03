import CoreAudio
import Foundation

/// Injectable HAL boundary; registration and removal run on the control queue.
struct CapturePropertyListeners {
    typealias Operation = (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue,
                          @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    let add: Operation
    let remove: Operation

    static let live = CapturePropertyListeners(add: { object, stored, queue, block in
        var address = stored
        return AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    }, remove: { object, stored, queue, block in
        var address = stored
        return AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    })
}

/// Confined to the capture lifecycle queue. Property callbacks never touch the
/// realtime ring; they coalesce into a rebuild after the device settles.
final class CaptureDeviceFormatObserver {
    private let queue: DispatchQueue
    private let listeners: CapturePropertyListeners
    private let willChange: () -> Void
    private let changed: () -> Void
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listener: AudioObjectPropertyListenerBlock?
    private var generation: UInt64 = 0
    private var changePending = false

    init(queue: DispatchQueue, listeners: CapturePropertyListeners,
         willChange: @escaping () -> Void = {}, changed: @escaping () -> Void) {
        self.queue = queue
        self.listeners = listeners
        self.willChange = willChange
        self.changed = changed
    }

    func install(deviceID: AudioDeviceID, streamIDs: [AudioObjectID]) throws {
        remove()
        let currentGeneration = generation
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleChange(generation: currentGeneration)
        }
        listener = block
        func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
            -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                       mElement: kAudioObjectPropertyElementMain)
        }
        var targets: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (deviceID, address(kAudioDevicePropertyNominalSampleRate)),
            (deviceID, address(kAudioDevicePropertyDeviceIsAlive)),
            (deviceID, address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)),
        ]
        for stream in streamIDs {
            targets.append((stream, address(kAudioStreamPropertyVirtualFormat)))
            targets.append((stream, address(kAudioStreamPropertyPhysicalFormat)))
        }
        do {
            for (object, address) in targets {
                let status = listeners.add(object, address, queue, block)
                guard status == noErr else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                        NSLocalizedDescriptionKey: "Install capture device-format listener failed: \(status)"])
                }
                registrations.append((object, address))
            }
        } catch {
            remove()
            throw error
        }
    }

    func remove() {
        generation &+= 1
        changePending = false
        if let listener {
            for (object, address) in registrations {
                _ = listeners.remove(object, address, queue, listener)
            }
        }
        registrations.removeAll()
        listener = nil
    }

    private func scheduleChange(generation: UInt64) {
        guard generation == self.generation, !changePending else { return }
        changePending = true
        willChange()
        queue.asyncAfter(deadline: .now() + .milliseconds(75)) { [weak self] in
            guard let self, generation == self.generation, self.changePending else { return }
            self.changePending = false
            self.changed()
        }
    }
}
