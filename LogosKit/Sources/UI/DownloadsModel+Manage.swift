import Domain
import Downloads
import Foundation

extension DownloadsModel {
    /// The downloaded Books in the chosen ``order``.
    public var downloaded: [DownloadRow] { list.downloaded(in: order) }

    /// Moves queue rows (from a drag). Only queued Books move: the active and failed ones keep their places, and the
    /// queued ones fill the other places in their new order. Shown at once, then written.
    public func moveQueued(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var moved = list.queue
        moved.move(fromOffsets: source, toOffset: destination)
        let queued = moved.filter { $0.state == .queued }
        var next = queued.makeIterator()
        let queue = list.queue.map { $0.state == .queued ? next.next() ?? $0 : $0 }
        list = DownloadsList(queue: queue, downloaded: list.downloaded)
        await downloader?.reorder(queued.map(\.id))
    }

    /// The Downloads launch file check, in the background after the first frame and before ``resume()``.
    public func checkFiles() async {
        await downloader?.checkFiles()
    }
}
