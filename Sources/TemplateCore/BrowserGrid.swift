import Foundation

/// The arithmetic behind arrow keys in the icon view, kept apart from the view so it can be checked.
public enum BrowserGrid {
    public enum Direction { case left, right, up, down }
    /// How many icons an adaptive grid with this minimum width and spacing puts in a row of the given width.
    public static func columns(width: Double, minimum: Double, spacing: Double) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }
    /// The item an arrow key selects. Left and right stay inside the row; up and down move by one row, so by `columns`
    /// items; down from a row that has no item below goes to the last item. Nothing selected starts at the first or last item.
    public static func next(from index: Int?, count: Int, columns: Int, _ direction: Direction) -> Int? {
        guard count > 0 else { return nil }
        let columns = max(1, columns)
        guard let index, (0..<count).contains(index) else { return (direction == .left || direction == .up) ? count - 1 : 0 }
        let row = index / columns, column = index % columns
        switch direction {
        case .left: return column == 0 ? index : index - 1
        case .right: return (column == columns - 1 || index == count - 1) ? index : index + 1
        case .up: return row == 0 ? index : index - columns
        case .down:
            if index + columns < count { return index + columns }
            return row == (count - 1) / columns ? index : count - 1
        }
    }
}
