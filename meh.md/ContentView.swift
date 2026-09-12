import SwiftUI

struct ContentView: View {
    @State private var text = """
    # A quieter place to write

    The Markdown stays **visible**, including _emphasis_, `code`, and
    [links](https://example.com).

    - Write on Mac
    - Continue on iPhone or iPad
    - Keep every character: café, naïve, 👋🏽
    """

    var body: some View {
        MarkdownEditor(text: $text)
    }
}

#Preview {
    ContentView()
}
