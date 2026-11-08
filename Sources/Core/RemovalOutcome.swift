import Foundation

struct RemovalOutcome {
    var bytes: Int64 = 0
    var removed = 0
    var failed = 0

    var summary: String {
        if failed > 0 {
            return "Removed an estimated " + human(bytes) + "; \(failed) operation(s) need attention. Check permissions and try again."
        }
        return removed > 0 ? "Removed an estimated " + human(bytes) : "Nothing to remove"
    }
}
