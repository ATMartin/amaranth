import Foundation
import Darwin
import Domain
import Storage
import MeetingAccess

/// T98 scale: seed N synthetic meetings × L lines, then time list/search/get. `cold` runs one operation of each kind
/// in a fresh process (new store, nothing cached by the app; the OS file cache may be warm); `warm` repeats them in one
/// process. Reports p50/p95 and peak memory footprint.
enum Scale {
    static func seed(root: URL, meetings: Int, lines: Int) throws {
        let store = try MeetingStore(root: root)
        var r = Synthetic.RNG(state: 7)
        let folder = try store.createFolder(name: "Clients").id
        let start = Date(timeIntervalSince1970: 1_788_220_800)
        for i in 0..<meetings {
            let ls = (0..<lines).map { _ in Synthetic.fillerLine(&r) }
            try Synthetic.meeting(store, key: "scale\(i)", title: "Synthetic meeting \(i)", start: start.addingTimeInterval(Double(i) * 3600),
                                  lines: ls, people: [Synthetic.names[i % 10], Synthetic.names[(i + 3) % 10]], folder: i % 3 == 0 ? folder : nil,
                                  notes: ["\(Synthetic.names[i % 10]) owns the \(Synthetic.topics[i % 20]) follow up"])
            if i % 25 == 0 { print("seeded \(i + 1)/\(meetings)") }
        }
    }

    static let queries = ["budget", "release notes", "hiring plan owner", "who owns the dashboard follow up", "pricing page behind", "data migration",
                          "mobile app needs another pass", "status page", "customer survey", "documentation on track"]

    static func peakFootprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
    }

    /// Runs `ops` operations cycling list, search, get(metadata), get(transcript first page); prints JSON lines.
    static func run(root: URL, ops: Int, label: String) throws {
        let t0 = Date()
        let store = try MeetingStore(root: root)
        let reader = MeetingReader(store: store)
        let openMs = Date().timeIntervalSince(t0) * 1000
        let ids = try store.liveMeetingIDs()
        var times: [String: [Double]] = [:]
        var r = Synthetic.RNG(state: 99)
        for i in 0..<ops {
            let kind = ["list", "search", "getMetadata", "getTranscript"][i % 4]
            let t = Date()
            switch kind {
            case "list": _ = try reader.listMeetings(ListMeetingsRequest(filter: i % 8 == 0 ? MeetingFilter(participant: "Ana") : MeetingFilter(), limit: 50))
            case "search": _ = try reader.searchMeetings(SearchMeetingsRequest(query: queries.randomElement(using: &r)!, limit: 20))
            case "getMetadata": _ = try reader.getMeeting(GetMeetingRequest(meetingID: ids.randomElement(using: &r)!.rawValue, section: .metadata))
            default: _ = try reader.getMeeting(GetMeetingRequest(meetingID: ids.randomElement(using: &r)!.rawValue, section: .transcript))
            }
            times[kind, default: []].append(Date().timeIntervalSince(t) * 1000)
        }
        var out: [String: Any] = ["label": label, "openMs": openMs, "peakFootprintMiB": peakFootprintMiB(), "meetings": ids.count]
        for (k, v) in times { out[k] = v }
        print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
    }
}
