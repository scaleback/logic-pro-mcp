import CoreMIDI
import Foundation

/// Channel that routes operations through CoreMIDI / MMC.
actor CoreMIDIChannel: Channel {
    let id: ChannelID = .coreMIDI
    private let engine: any CoreMIDIEngineProtocol
    private let portManager: (any VirtualPortManaging)?
    private static let maxSysExBytes = 1024
    private static let maxSysExTextCharacters = maxSysExBytes * 5

    private struct ValidationFailure: Error {
        let message: String
    }

    /// Project constants a LOCATE needs and AX cannot read. `nil` disables MMC
    /// playhead positioning entirely — see `ProjectSyncSettings`.
    private let projectSync: ProjectSyncSettings?
    /// Transport read used to VERIFY a LOCATE. `nil` (the production case)
    /// means "go through the AX helper"; tests inject a stub instead.
    ///
    /// This is NOT a direct AX call, and must never become one: this process is
    /// sandboxed and not Accessibility-trusted, so direct AX here returns
    /// nothing silently and the verification would never succeed. See
    /// `TransportObserver`.
    private let observeTransport: (@Sendable () async -> TransportObserver.Reading?)?
    /// Created on first use rather than at init so constructing a channel never
    /// touches the helper's LaunchAgent.
    private var helperProxy: (any Channel)?
    private let sleepNanos: @Sendable (UInt64) async -> Void

    init(
        engine: any CoreMIDIEngineProtocol,
        portManager: (any VirtualPortManaging)? = nil,
        projectSync: ProjectSyncSettings? = ProjectSyncSettings.fromEnvironment(),
        observeTransport: (@Sendable () async -> TransportObserver.Reading?)? = nil,
        sleepNanos: @escaping @Sendable (UInt64) async -> Void = {
            try? await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.engine = engine
        self.portManager = portManager
        self.projectSync = projectSync
        self.observeTransport = observeTransport
        self.sleepNanos = sleepNanos
    }

    func start() async throws {
        try await engine.start()
        Log.info("CoreMIDIChannel started", subsystem: "midi")
    }

    func stop() async {
        await engine.stop()
        Log.info("CoreMIDIChannel stopped", subsystem: "midi")
    }

    /// Parse a MIDI-spec-bounded UInt8 from a param string (0-127 inclusive).
    /// Rejects UInt8 128-255 which are valid Swift values but outside MIDI data
    /// byte range; also rejects non-numeric / out-of-range ints.
    private static func midiData7(_ s: String?) -> UInt8? {
        guard let s, let v = Int(s), (0...127).contains(v) else { return nil }
        return UInt8(v)
    }

    /// Parse a channel-layer MIDI wire byte. Public tool input is 1-based
    /// and converted by `MIDIDispatcher`; direct channel calls must not accept
    /// channel 16 and rely on the engine's `& 0x0F` masking to wrap it to 0.
    private static func midiChannel(_ s: String?) -> UInt8? {
        guard let s, let v = Int(s), (0...15).contains(v) else { return nil }
        return UInt8(v)
    }

    /// Parse an optional `channel` param into a wire byte (0-15), defaulting to
    /// 0 when absent. Returns `.failure` (NOT throw): the `execute` catch that
    /// wraps `MIDIEngineError` into a State C envelope would re-wrap a thrown
    /// validation miss too, but these misses are test-pinned plain `.error`
    /// strings, so the caller maps `.failure` straight to `.error(message)`.
    private static func parseChannel(_ raw: String?, label: String) -> Result<UInt8, ValidationFailure> {
        guard let raw else { return .success(0) }
        guard let parsed = midiChannel(raw) else {
            return .failure(ValidationFailure(message: "\(label) 'channel' must be a wire byte in 0-15"))
        }
        return .success(parsed)
    }

    /// Parse an optional `velocity` param into a 7-bit value (0-127), defaulting
    /// to `defaultValue` when absent. Returns `.failure` (NOT throw) for the same
    /// reason as `parseChannel`.
    private static func parseVelocity(_ raw: String?, label: String, default defaultValue: UInt8) -> Result<UInt8, ValidationFailure> {
        guard let raw else { return .success(defaultValue) }
        guard let parsed = midiData7(raw) else {
            return .failure(ValidationFailure(message: "\(label) 'velocity' must be in 0-127"))
        }
        return .success(parsed)
    }

    private static func durationMs(_ s: String?, default defaultValue: UInt64) -> UInt64? {
        guard let s else { return defaultValue }
        guard let value = UInt64(s), (1...30_000).contains(value) else { return nil }
        return value
    }

    private static func midiData7CSV(_ s: String?) -> [UInt8]? {
        guard let s else { return nil }
        let tokens = s
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...24).contains(tokens.count) else { return nil }
        var values: [UInt8] = []
        for token in tokens {
            guard let value = Int(token), (0...127).contains(value) else { return nil }
            values.append(UInt8(value))
        }
        return values
    }

    private static func parseSysexHexBytes(_ raw: String) -> Result<[UInt8], ValidationFailure> {
        guard raw.count <= maxSysExTextCharacters else {
            return .failure(ValidationFailure(message: "SysEx payload exceeds \(maxSysExBytes)-byte limit"))
        }
        let tokens = raw
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else {
            return .failure(ValidationFailure(message: "SysEx bytes must contain at least one hex token"))
        }
        var bytes: [UInt8] = []
        for token in tokens {
            guard let byte = UInt8(token, radix: 16) else {
                return .failure(ValidationFailure(message: "SysEx contains invalid hex token '\(token)'"))
            }
            bytes.append(byte)
        }
        guard bytes.count <= maxSysExBytes else {
            return .failure(ValidationFailure(message: "SysEx payload exceeds \(maxSysExBytes)-byte limit"))
        }
        return .success(bytes)
    }

    private static func sendOnlySuccess(
        operation: String,
        legacyMessage: String,
        extras: [String: Any] = [:]
    ) -> ChannelResult {
        var merged: [String: Any] = [
            "operation": operation,
            "legacy_message": legacyMessage,
        ]
        for (key, value) in extras {
            merged[key] = value
        }
        return .success(HonestContract.encodeStateB(
            reason: .sendOnlyNoReadback,
            extras: merged
        ))
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        // Guard: refuse work when CoreMIDI client / virtual source not active.
        // Without this, every send returns .success even though no MIDI is
        // actually transmitted (silent failure — see prod-hardening review #5).
        if !(await engine.isActive) {
            return .error(HonestContract.encodeStateC(
                error: .portUnavailable,
                hint: "CoreMIDI engine not active (virtual source not published)",
                extras: ["operation": operation, "channel": "CoreMIDI"]
            ))
        }
        do {
            switch operation {
        // MARK: - Transport (MMC)

        case "transport.play":
            let bytes = MMCCommands.play()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC play sent",
                extras: ["byte_count": bytes.count]
            )

        case "transport.stop":
            let bytes = MMCCommands.stop()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC stop sent",
                extras: ["byte_count": bytes.count]
            )

        case "transport.pause":
            let bytes = MMCCommands.pause()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC pause sent",
                extras: ["byte_count": bytes.count]
            )

        case "transport.record_strobe":
            let bytes = MMCCommands.recordStrobe()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC record strobe sent",
                extras: ["byte_count": bytes.count]
            )

        case "transport.record_exit":
            let bytes = MMCCommands.recordExit()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC record exit sent",
                extras: ["byte_count": bytes.count]
            )

        case "transport.fast_forward":
            let bytes = MMCCommands.fastForward()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC fast forward sent",
                extras: ["byte_count": bytes.count]
            )

        case "transport.rewind":
            let bytes = MMCCommands.rewind()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC rewind sent",
                extras: ["byte_count": bytes.count]
            )

        case "transport.locate":
            guard let h = params["hours"].flatMap(UInt8.init),
                  let m = params["minutes"].flatMap(UInt8.init),
                  let s = params["seconds"].flatMap(UInt8.init),
                  let f = params["frames"].flatMap(UInt8.init) else {
                return .error("locate requires hours, minutes, seconds, frames")
            }
            let sf = params["subframes"].flatMap(UInt8.init) ?? 0
            let bytes = MMCCommands.locate(hours: h, minutes: m, seconds: s, frames: f, subframes: sf)
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC locate sent to \(h):\(m):\(s):\(f).\(sf)",
                extras: [
                    "byte_count": bytes.count,
                    "time": "\(h):\(m):\(s):\(f).\(sf)",
                ]
            )

        // MARK: - Note Send

        case "midi.send_note":
            guard let note = Self.midiData7(params["note"]) else {
                return .error("send_note requires 'note' in 0-127")
            }
            let velocity: UInt8
            switch Self.parseVelocity(params["velocity"], label: "send_note", default: 100) {
            case .success(let parsed): velocity = parsed
            case .failure(let failure): return .error(failure.message)
            }
            let channel: UInt8
            switch Self.parseChannel(params["channel"], label: "send_note") {
            case .success(let parsed): channel = parsed
            case .failure(let failure): return .error(failure.message)
            }
            guard let durationMs = Self.durationMs(params["duration_ms"], default: 500) else {
                return .error("send_note 'duration_ms' must be in 1-30000")
            }
            try await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            do {
                try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
                try await engine.sendNoteOff(channel: channel, note: note, velocity: 0)
            } catch {
                // The throwing-MIDIEngine conversion newly exposes a stuck-note
                // path: if the note-off throws, the on already sounded. Mirror
                // send_chord and best-effort a second note-off before rethrowing
                // so a transient failure still silences the note (State C stays
                // truthful via the top-level catch).
                await bestEffortCoreMIDINoteOffs([note], channel: channel)
                throw error
            }
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Note \(note) on ch \(channel) vel \(velocity) dur \(durationMs)ms",
                extras: [
                    "note": Int(note),
                    "velocity": Int(velocity),
                    "channel_wire": Int(channel),
                    "duration_ms": Int(durationMs),
                    "message_count": 2,
                ]
            )

        case "midi.note_on":
            guard let note = Self.midiData7(params["note"]) else {
                return .error("note_on requires 'note' in 0-127")
            }
            let velocity: UInt8
            switch Self.parseVelocity(params["velocity"], label: "note_on", default: 100) {
            case .success(let parsed): velocity = parsed
            case .failure(let failure): return .error(failure.message)
            }
            let channel: UInt8
            switch Self.parseChannel(params["channel"], label: "note_on") {
            case .success(let parsed): channel = parsed
            case .failure(let failure): return .error(failure.message)
            }
            try await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Note on \(note) ch \(channel) vel \(velocity)",
                extras: [
                    "note": Int(note),
                    "velocity": Int(velocity),
                    "channel_wire": Int(channel),
                    "message_count": 1,
                ]
            )

        case "midi.note_off":
            guard let note = Self.midiData7(params["note"]) else {
                return .error("note_off requires 'note' in 0-127")
            }
            let channel: UInt8
            switch Self.parseChannel(params["channel"], label: "note_off") {
            case .success(let parsed): channel = parsed
            case .failure(let failure): return .error(failure.message)
            }
            try await engine.sendNoteOff(channel: channel, note: note, velocity: 0)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Note off \(note) ch \(channel)",
                extras: [
                    "note": Int(note),
                    "velocity": 0,
                    "channel_wire": Int(channel),
                    "message_count": 1,
                ]
            )

        // MARK: - CC

        case "midi.send_cc":
            guard let controller = Self.midiData7(params["controller"]) else {
                return .error("send_cc requires 'controller' and 'value' — 'controller' must be in 0-127")
            }
            guard let value = Self.midiData7(params["value"]) else {
                return .error("send_cc requires 'controller' and 'value' — 'value' must be in 0-127")
            }
            let channel: UInt8
            switch Self.parseChannel(params["channel"], label: "send_cc") {
            case .success(let parsed): channel = parsed
            case .failure(let failure): return .error(failure.message)
            }
            try await engine.sendCC(channel: channel, controller: controller, value: value)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "CC \(controller)=\(value) on ch \(channel)",
                extras: [
                    "controller": Int(controller),
                    "value": Int(value),
                    "channel_wire": Int(channel),
                    "message_count": 1,
                ]
            )

        // MARK: - Program Change

        case "midi.program_change", "midi.send_program_change":
            guard let program = Self.midiData7(params["program"]) else {
                return .error("program_change requires 'program' in 0-127")
            }
            let channel: UInt8
            switch Self.parseChannel(params["channel"], label: "program_change") {
            case .success(let parsed): channel = parsed
            case .failure(let failure): return .error(failure.message)
            }
            try await engine.sendProgramChange(channel: channel, program: program)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Program change \(program) on ch \(channel)",
                extras: [
                    "program": Int(program),
                    "channel_wire": Int(channel),
                    "message_count": 1,
                ]
            )

        // MARK: - Pitch Bend

        case "midi.pitch_bend", "midi.send_pitch_bend":
            guard let rawValue = params["value"].flatMap(Int.init),
                  (0...16_383).contains(rawValue),
                  let value = UInt16(exactly: rawValue) else {
                return .error("pitch_bend requires 'value' (0-16383, center=8192)")
            }
            let channel: UInt8
            switch Self.parseChannel(params["channel"], label: "pitch_bend") {
            case .success(let parsed): channel = parsed
            case .failure(let failure): return .error(failure.message)
            }
            try await engine.sendPitchBend(channel: channel, value: value)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Pitch bend \(value) on ch \(channel)",
                extras: [
                    "value": Int(value),
                    "channel_wire": Int(channel),
                    "message_count": 1,
                ]
            )

        // MARK: - Aftertouch

        case "midi.aftertouch", "midi.send_aftertouch":
            guard let pressure = Self.midiData7(params["pressure"] ?? params["value"]) else {
                return .error("aftertouch requires 'pressure' (0-127)")
            }
            let channel: UInt8
            switch Self.parseChannel(params["channel"], label: "aftertouch") {
            case .success(let parsed): channel = parsed
            case .failure(let failure): return .error(failure.message)
            }
            try await engine.sendAftertouch(channel: channel, pressure: pressure)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Aftertouch \(pressure) on ch \(channel)",
                extras: [
                    "pressure": Int(pressure),
                    "channel_wire": Int(channel),
                    "message_count": 1,
                ]
            )

        // MARK: - Raw SysEx

        case "midi.send_sysex":
            guard let hexString = params["bytes"] ?? params["data"] else {
                return .error("send_sysex requires 'bytes' (hex string, e.g. 'F0 7F 7F 06 02 F7')")
            }
            // Support space/comma-separated hex tokens with optional 0x prefix.
            let bytes: [UInt8]
            switch Self.parseSysexHexBytes(hexString) {
            case .success(let parsed):
                bytes = parsed
            case .failure(let failure):
                return .error(failure.message)
            }
            // Valid SysEx: F0 <at least 1 data byte> F7, no internal F0/F7.
            // 0xF7 only legal at final position; 0xF0 only legal at start.
            guard bytes.count >= 3, bytes.first == 0xF0, bytes.last == 0xF7 else {
                return .error("SysEx must start with F0 and end with F7 and have at least one data byte (parsed \(bytes.count) bytes from '\(hexString.prefix(60))')")
            }
            let interior = bytes.dropFirst().dropLast()
            if interior.contains(0xF0) || interior.contains(0xF7) {
                return .error("SysEx contains illegal internal 0xF0/0xF7 byte")
            }
            guard interior.allSatisfy({ $0 <= 0x7F }) else {
                return .error("SysEx body bytes must be 0x00-0x7F; only first F0 and final F7 may be status bytes")
            }
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "SysEx sent (\(bytes.count) bytes)",
                extras: ["byte_count": bytes.count]
            )

        // Aliases for router operation keys
        case "midi.send_chord":
            // Chord = multiple note-ons. Parse and validate.
            guard let notes = Self.midiData7CSV(params["notes"]) else {
                return .error("send_chord 'notes' must contain 1..24 MIDI notes, each integer 0..127")
            }
            let vel: UInt8
            switch Self.parseVelocity(params["velocity"], label: "send_chord", default: 80) {
            case .success(let parsed): vel = parsed
            case .failure(let failure): return .error(failure.message)
            }
            let ch: UInt8
            switch Self.parseChannel(params["channel"], label: "send_chord") {
            case .success(let parsed): ch = parsed
            case .failure(let failure): return .error(failure.message)
            }
            guard let durMs = Self.durationMs(params["duration_ms"], default: 500) else {
                return .error("send_chord 'duration_ms' must be in 1-30000")
            }
            var startedNotes: [UInt8] = []
            do {
                for n in notes {
                    try await engine.sendNoteOn(channel: ch, note: n, velocity: vel)
                    startedNotes.append(n)
                }
            } catch {
                await bestEffortCoreMIDINoteOffs(startedNotes, channel: ch)
                throw error
            }
            try? await Task.sleep(nanoseconds: durMs * 1_000_000)
            try await sendCoreMIDINoteOffs(notes, channel: ch)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Chord sent: \(notes.count) notes",
                extras: [
                    "note_count": notes.count,
                    "velocity": Int(vel),
                    "channel_wire": Int(ch),
                    "duration_ms": Int(durMs),
                    "message_count": notes.count * 2,
                ]
            )

        case "midi.play_sequence":
            // Tight-rhythm sequencer: parse `notes` as semicolon-separated
            // events "note,offsetMs,durationMs[,velocity[,channel]]".  Each
            // event scheduled relative to the first — server-side timing is
            // jittery at ±5 ms but far tighter than round-tripping 20+ MCP
            // send_note calls per bar from a client.
            // Example: "60,0,400;64,500,400;67,1000,400" = C-E-G arpeggio.
            // T3 — strict whole-parse-fail. NoteSequenceParser now returns a
            // Result, with ch field 1-based (1..16) on input → wire byte
            // 0..15 computed inside the parser. A single bad segment fails
            // the whole batch so the agent can self-correct rather than
            // have N-1 notes mysteriously survive.
            let events: [NoteSequenceParser.ParsedNote]
            switch NoteSequenceParser.parse(params["notes"] ?? "") {
            case .success(let parsed):
                events = parsed
            case .failure(let err):
                return .error("play_sequence: \(err.hint)")
            }
            guard !events.isEmpty else {
                return .error("play_sequence 'notes' must be 'note,offset,dur[,vel[,ch]];...'")
            }
            guard events.count <= 256 else {
                return .error("play_sequence 'notes' count must be ≤ 256 (got \(events.count))")
            }
            if let violation = NoteSequenceParser.realtimeTimingViolation(in: events) {
                return .error("play_sequence: \(violation)")
            }
            let startNs = DispatchTime.now().uptimeNanoseconds
            var noteOffTasks: [Task<Void, Error>] = []
            for event in events {
                let targetNs = startNs + UInt64(event.offsetMs) * 1_000_000
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if targetNs > nowNs {
                    try? await Task.sleep(nanoseconds: targetNs - nowNs)
                }
                do {
                    try await engine.sendNoteOn(channel: event.channel, note: event.pitch, velocity: event.velocity)
                } catch {
                    await drainCoreMIDINoteOffTasks(noteOffTasks)
                    throw error
                }
                let pitch = event.pitch
                let ch = event.channel
                let durNs = UInt64(event.durationMs) * 1_000_000
                let engine = self.engine
                noteOffTasks.append(Task {
                    try await Task.sleep(nanoseconds: durNs)
                    try await engine.sendNoteOff(channel: ch, note: pitch, velocity: 0)
                })
            }
            if let lastEnd = events.map({ $0.offsetMs + $0.durationMs }).max() {
                let endTargetNs = startNs + UInt64(lastEnd) * 1_000_000
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if endTargetNs > nowNs {
                    try? await Task.sleep(nanoseconds: endTargetNs - nowNs)
                }
            }
            try await waitForCoreMIDINoteOffTasks(noteOffTasks)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Sequence sent: \(events.count) events",
                extras: [
                    "event_count": events.count,
                    "message_count": events.count * 2,
                ]
            )

        case "midi.step_input":
            guard let note = Self.midiData7(params["note"]) else {
                return .error("step_input requires explicit 'note' in 0-127")
            }
            guard let durationMs = stepInputDurationMs(from: params["duration"] ?? params["duration_ms"]) else {
                return .error("step_input requires explicit 'duration' or 'duration_ms' in 1-30000 or 1/1..1/32")
            }
            let vel: UInt8 = 80
            try await engine.sendNoteOn(channel: 0, note: note, velocity: vel)
            do {
                try? await Task.sleep(for: .milliseconds(durationMs))
                try await engine.sendNoteOff(channel: 0, note: note, velocity: 0)
            } catch {
                // Same throwing-note-off stuck-note class as send_note: best-effort
                // a second note-off before rethrowing so step input cannot leave
                // a note sounding.
                await bestEffortCoreMIDINoteOffs([note], channel: 0)
                throw error
            }
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "Step input: note \(note), duration \(durationMs)ms",
                extras: [
                    "note": Int(note),
                    "velocity": Int(vel),
                    "channel_wire": 0,
                    "duration_ms": durationMs,
                    "message_count": 2,
                ]
            )

        case "midi.list_ports":
            return .success(listMIDIPortsJSON())

        case "midi.create_virtual_port":
            guard let portManager else {
                return .error("Dynamic virtual port creation unavailable in this context")
            }
            let name = String((params["name"] ?? "LogicProMCP-Virtual")
                .filter { !$0.isNewline && $0 != "\0" }
                .prefix(63))
            do {
                _ = try await portManager.createSendOnlyPort(name: name)
                return Self.sendOnlySuccess(
                    operation: operation,
                    legacyMessage: "Virtual port '\(name)' ready",
                    extras: ["port_name": name]
                )
            } catch MIDIPortError.modeConflict(
                name: let conflictName,
                existing: let existingMode,
                requested: let requestedMode
            ) {
                return .error(HonestContract.encodeStateC(
                    error: .portUnavailable,
                    hint: "Virtual port name collides with an existing port of a different mode",
                    extras: [
                        "operation": operation,
                        "channel": "CoreMIDI",
                        "port_name": conflictName,
                        "existing_mode": existingMode.rawValue,
                        "requested_mode": requestedMode.rawValue,
                    ]
                ))
            } catch {
                return .error("Failed to create virtual port '\(name)': \(error)")
            }

        case "midi.get_input_state":
            return .success("{\"active\":true}")

        case "transport.record":
            let bytes = MMCCommands.recordStrobe()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC record strobe",
                extras: ["byte_count": bytes.count]
            )

        case "transport.goto_position":
            return await gotoPositionViaMMCLocate(params: params)

        case "mmc.play":
            let bytes = MMCCommands.play()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC play",
                extras: ["byte_count": bytes.count]
            )

        case "mmc.stop":
            let bytes = MMCCommands.stop()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC stop",
                extras: ["byte_count": bytes.count]
            )

        case "mmc.record_strobe":
            let bytes = MMCCommands.recordStrobe()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC record strobe",
                extras: ["byte_count": bytes.count]
            )

        case "mmc.record_exit":
            let bytes = MMCCommands.recordExit()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC record exit",
                extras: ["byte_count": bytes.count]
            )

        case "mmc.locate":
            guard
                let time = params["time"],
                let components = parseMMCLocateTime(time)
            else {
                return .error("MMC locate requires time in HH:MM:SS:FF")
            }
            let bytes = MMCCommands.locate(
                hours: components.hours,
                minutes: components.minutes,
                seconds: components.seconds,
                frames: components.frames
            )
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC locate sent to \(time)",
                extras: [
                    "byte_count": bytes.count,
                    "time": time,
                ]
            )

        case "mmc.pause":
            let bytes = MMCCommands.pause()
            try await engine.sendSysEx(bytes)
            return Self.sendOnlySuccess(
                operation: operation,
                legacyMessage: "MMC pause",
                extras: ["byte_count": bytes.count]
            )

        default:
            return .error("Unknown CoreMIDI operation: \(operation)")
        }
        } catch {
            return .error(Self.coreMIDISendFailure(operation: operation, error: error))
        }
    }

    private static func coreMIDISendFailure(operation: String, error: any Error) -> String {
        let failure: HonestContract.FailureError
        if let midiError = error as? MIDIEngineError {
            switch midiError {
            case .notRunning:
                failure = .portUnavailable
            case .invalidSysEx:
                failure = .invalidParams
            default:
                failure = .axWriteFailed
            }
        } else {
            failure = .axWriteFailed
        }
        return HonestContract.encodeStateC(
            error: failure,
            hint: "CoreMIDI send failed for \(operation): \(error)",
            extras: ["operation": operation, "channel": "CoreMIDI"]
        )
    }

    private func sendCoreMIDINoteOffs(_ notes: [UInt8], channel: UInt8) async throws {
        var firstError: (any Error)?
        for note in notes {
            do {
                try await engine.sendNoteOff(channel: channel, note: note, velocity: 0)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func bestEffortCoreMIDINoteOffs(_ notes: [UInt8], channel: UInt8) async {
        for note in notes {
            try? await engine.sendNoteOff(channel: channel, note: note, velocity: 0)
        }
    }

    private func waitForCoreMIDINoteOffTasks(_ tasks: [Task<Void, Error>]) async throws {
        var firstError: (any Error)?
        for task in tasks {
            do {
                try await task.value
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func drainCoreMIDINoteOffTasks(_ tasks: [Task<Void, Error>]) async {
        for task in tasks {
            _ = await task.result
        }
    }

    func healthCheck() async -> ChannelHealth {
        let active = await engine.isActive
        if active {
            return .healthy(detail: "CoreMIDI client active, virtual ports created")
        } else {
            return .unavailable("CoreMIDI client not initialized")
        }
    }

    private func parseMMCLocateTime(_ time: String) -> (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8)? {
        let parts = time.split(separator: ":")
        guard parts.count == 4 else { return nil }
        guard
            let hours = UInt8(parts[0]),
            let minutes = UInt8(parts[1]),
            let seconds = UInt8(parts[2]),
            let frames = UInt8(parts[3])
        else {
            return nil
        }
        return (hours, minutes, seconds, frames)
    }

    private func stepInputDurationMs(from rawDuration: String?) -> Int? {
        guard let rawDuration, !rawDuration.isEmpty else { return nil }
        if let durationMs = Int(rawDuration) {
            guard (1...30_000).contains(durationMs) else { return nil }
            return durationMs
        }
        switch rawDuration {
        case "1/1": return 1000
        case "1/2": return 500
        case "1/4": return 250
        case "1/8": return 125
        case "1/16": return 63
        case "1/32": return 32
        default: return nil
        }
    }

    private func listMIDIPortsJSON() -> String {
        struct PortListing: Encodable {
            let sources: [String]
            let destinations: [String]
        }

        let listing = PortListing(
            sources: listEndpointNames(count: MIDIGetNumberOfSources(), getter: MIDIGetSource),
            destinations: listEndpointNames(count: MIDIGetNumberOfDestinations(), getter: MIDIGetDestination)
        )
        return encodeJSON(listing)
    }

    private func listEndpointNames(
        count: Int,
        getter: (Int) -> MIDIEndpointRef
    ) -> [String] {
        (0..<count).map { index in
            endpointName(getter(index))
        }
    }

    private func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var cfName: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cfName) == noErr,
           let name = cfName?.takeRetainedValue() as String? {
            return name
        }
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfName) == noErr,
           let name = cfName?.takeRetainedValue() as String? {
            return name
        }
        return "Unnamed MIDI Endpoint"
    }
}

// MARK: - Playhead positioning that does not steal focus (task #28)

extension CoreMIDIChannel {

    /// Move the playhead with an MMC LOCATE, then verify it landed by reading
    /// Logic's own bar slider over Accessibility.
    ///
    /// This is the only playhead move in the project that does not pull Logic
    /// to the front, which matters for more than comfort: when Logic steals
    /// focus mid-session the user's next keystrokes land in Logic and silently
    /// mutate their project.
    ///
    /// MMC is send-only, but that does not condemn this to State B — the
    /// verification comes from a *different* channel. AX reads reach Logic in
    /// the background (issue #440 is about synthetic keystrokes, not reads), so
    /// actuating over MIDI and reading back over AX is focus-free end to end.
    ///
    /// Every path that cannot prove the landing bar returns a NON-terminal
    /// `.error`, so `ChannelRouter` falls through to the Accessibility path —
    /// exact, but focus-taking. That keeps today's behaviour as the floor and
    /// adds the focus-free path strictly on top: an unconfigured or unverifiable
    /// run is no worse than before, and never reports a send as a success.
    func gotoPositionViaMMCLocate(params: [String: String]) async -> ChannelResult {
        guard let bar = Self.parseTargetBar(params) else {
            return .error("MMC locate needs 'bar' (1...9999) or a bar-relative 'position'")
        }
        guard let sync = projectSync else {
            return .error(
                "MMC playhead positioning is unconfigured: set \(ProjectSyncSettings.frameRateKey) "
                + "to the project's SMPTE frame rate. A LOCATE sent at a guessed rate raises Logic's "
                + "frame-rate modal, which then blocks every later operation until a human clears it."
            )
        }
        // ONE helper round trip, before anything is actuated. It supplies both
        // the tempo the conversion needs and the "before" bar the receipt needs,
        // and it fails closed: if the helper cannot be reached, nothing is sent.
        guard let before = await readTransport() else {
            return .error(
                "Transport state unreadable through the AX helper, so bar \(bar) can be neither "
                + "converted to SMPTE nor verified; nothing was sent."
            )
        }
        let tempo = before.tempo
        guard let smpte = MMCCommands.barBeatToSMPTE(
            bar: bar,
            beat: 1.0,
            tempo: tempo,
            beatsPerBar: sync.beatsPerBar,
            frameRate: sync.frameRate,
            smpteStartSeconds: sync.smpteStartSeconds
        ) else {
            return .error("Bar \(bar) at \(tempo) BPM falls outside the 24-hour SMPTE range")
        }

        let timecode = String(
            format: "%02d:%02d:%02d:%02d",
            smpte.hours, smpte.minutes, smpte.seconds, smpte.frames
        )

        let bytes: [UInt8]
        do {
            bytes = try MMCCommands.locateStrict(
                hours: smpte.hours,
                minutes: smpte.minutes,
                seconds: smpte.seconds,
                frames: smpte.frames,
                subframes: smpte.subframes,
                frameRate: sync.frameRate
            )
        } catch {
            return .error("MMC locate rejected \(timecode): \(error)")
        }

        do {
            try await engine.sendSysEx(bytes)
        } catch {
            return .error("Failed to send MMC locate for bar \(bar): \(error)")
        }

        let observed = await waitForPlayhead(bar: bar)

        var extras: [String: Any] = [
            "operation": "transport.goto_position",
            "method": "mmc_locate",
            "requested": "\(bar).1.1.1",
            "timecode": timecode,
            "frame_rate": sync.frameRate.configKey,
            "tempo": tempo,
            "beats_per_bar": sync.beatsPerBar,
            "smpte_start_seconds": sync.smpteStartSeconds,
            "stole_focus": false,
        ]
        extras["observed"] = observed.map { "\($0).1.1.1" } ?? NSNull()

        guard let observed else {
            return .error(
                "MMC locate to bar \(bar) (\(timecode)) was sent, but the bar slider could not be "
                + "read, so the landing is unverified."
            )
        }
        guard observed == bar else {
            return .error(
                "MMC locate aimed at bar \(bar) (\(timecode)) but the playhead reads bar \(observed). "
                + "Check that \(ProjectSyncSettings.beatsPerBarKey) and "
                + "\(ProjectSyncSettings.smpteStartKey) match the project, and that Project Settings → "
                + "Synchronization → MIDI → 'Listen to MMC input' is enabled."
            )
        }

        // Honest about causation: matching a bar the playhead already sat on
        // proves the position, not that the LOCATE was what put it there.
        // Reading the bar BEFORE actuating is what makes this honest: a locate to
        // the bar the playhead already occupied is indistinguishable from a
        // locate that never arrived — both read back as a match.
        extras["already_at_target"] = (before.bar == bar)
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    /// Poll for the playhead to reach `bar`, bounded by WALL-CLOCK time.
    ///
    /// The budget must count the reads, not just the sleeps between them. Each
    /// read is a FIFO round trip to the AX helper — measured live 2026-09-06 at
    /// roughly 2.5 s, not the microseconds an in-process AX read would cost. The
    /// first version budgeted 800 ms of *sleep* across up to eleven reads and so
    /// actually ran for ~30 s, blowing the server's 25 s deadline before the
    /// Accessibility fallback ever got its turn: the operation timed out even
    /// though the fallback would have succeeded in four more seconds.
    ///
    /// `maxWaitSeconds` is therefore deliberately small. Overshooting does not
    /// buy a better answer — it just spends the deadline that the fallback needs.
    /// Bounded by BOTH a wall-clock budget and a read count, because each bound
    /// covers a case the other cannot. In production the clock stops the loop:
    /// reads are slow and the deadline is what matters. Under test the sleep is
    /// a no-op and reads are instant, so the clock would never advance and the
    /// loop would spin — there the read cap stops it.
    private func waitForPlayhead(
        bar: Int,
        maxWaitSeconds: Double = 6.0,
        maxReads: Int = 6
    ) async -> Int? {
        let started = Date()
        var latest: Int? = await readTransport()?.bar
        var reads = 1

        while latest != bar,
              reads < maxReads,
              Date().timeIntervalSince(started) < maxWaitSeconds {
            await sleepNanos(200_000_000)   // 200 ms
            latest = await readTransport()?.bar
            reads += 1
        }
        return latest
    }

    /// Read the transport, through the injected stub when tests supply one and
    /// through the AX helper otherwise.
    private func readTransport() async -> TransportObserver.Reading? {
        if let observeTransport { return await observeTransport() }
        if helperProxy == nil { helperProxy = AXHelperProxyChannel() }
        guard let helperProxy else { return nil }
        return await TransportObserver.read(via: helperProxy)
    }

    /// Accept the same position spellings the Accessibility path accepts, so
    /// swapping channels never changes what a caller may write.
    static func parseTargetBar(_ params: [String: String]) -> Int? {
        var candidate: Int?
        if let barStr = params["bar"], let b = Int(barStr) {
            candidate = b
        } else if let pos = params["position"] {
            // Timecode is the MCU/`mmc.locate` path's input, not this one.
            guard !pos.contains(":") else { return nil }
            if let first = pos.split(separator: ".").first, let b = Int(first) {
                candidate = b
            }
        }
        guard let bar = candidate, (1...9999).contains(bar) else { return nil }
        return bar
    }
}
