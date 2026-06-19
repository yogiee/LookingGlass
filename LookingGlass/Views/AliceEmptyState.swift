import SwiftUI

/// The launch / no-chat-open state: full-body Alice with a comic speech bubble.
///
/// Quotes are organized into SETS. On each appearance we pick a random set AND a random
/// line within it; tapping the bubble re-rolls only within that launch's set (never an
/// immediate repeat). So a single session only ever reveals one set's worth of lines —
/// the rest stay hidden until the next launch, keeping the gag from showing its whole hand.
struct AliceEmptyState: View {
    @State private var setIndex: Int
    @State private var quoteIndex: Int
    @State private var hovering = false

    init() {
        let s = Int.random(in: 0..<AliceQuotes.sets.count)
        _setIndex = State(initialValue: s)
        _quoteIndex = State(initialValue: Int.random(in: 0..<AliceQuotes.sets[s].count))
    }

    private var quote: String { AliceQuotes.sets[setIndex][quoteIndex] }

    var body: some View {
        HStack(alignment: .top, spacing: -6) {
            bubble
                .padding(.top, 24)            // float beside Alice's head, not her feet
            Asset.image("alice-full")
                .scaledToFit()
                .frame(height: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)                 // lift the pair above the input bar
    }

    private var bubble: some View {
        Text(quote)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.82))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 230)
            .padding(.vertical, 13)
            .padding(.leading, 16)
            .padding(.trailing, 16 + BubbleShape.tail)   // room for the tail
            .background(
                BubbleShape().fill(Color(white: 0.98))
                    .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 4)
            )
            .overlay(BubbleShape().stroke(Color.black.opacity(0.10), lineWidth: 1))
            .scaleEffect(hovering ? 1.02 : 1.0)
            .contentShape(BubbleShape())
            .onTapGesture { reroll() }
            .onHover { hovering = $0 }
            .help("Tap for another thought")
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: quoteIndex)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func reroll() {
        let count = AliceQuotes.sets[setIndex].count
        guard count > 1 else { return }
        var next = quoteIndex
        while next == quoteIndex { next = Int.random(in: 0..<count) }
        quoteIndex = next
    }
}

/// Rounded-rectangle speech bubble with a tail on the trailing edge, pointing toward Alice.
private struct BubbleShape: Shape {
    static let tail: CGFloat = 14
    var radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width - Self.tail, height: rect.height)
        var p = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        // Tail: a small triangle off the right edge, tip pointing right at Alice's head.
        let cy = body.minY + body.height * 0.42
        p.move(to: CGPoint(x: body.maxX - 2, y: cy - Self.tail))
        p.addLine(to: CGPoint(x: rect.maxX, y: cy))
        p.addLine(to: CGPoint(x: body.maxX - 2, y: cy + Self.tail))
        p.closeSubpath()
        return p
    }
}

/// Wonderland-flavored lines in Alice's voice — dry-witted, warm, research-inviting.
/// Grouped into sets so each session reveals only one set (see AliceEmptyState).
/// Generic public Alice (ships in the repo); keep the voice, not anything personal.
enum AliceQuotes {
    static let sets: [[String]] = [
        // Rabbit hole / questions
        [
            "Down the rabbit hole is just a dramatic way of saying good question. Ask me one.",
            "Every rabbit hole has a bottom. Usually it's a citation. Where do we dig?",
            "I followed a white rabbit here. Turned out to be a footnote. Worth it.",
            "Curiosity didn't kill anyone in this story. It just kept asking better questions.",
            "Mind the rabbit hole — or don't. That's usually where the interesting things are.",
        ],
        // Looking glass / perspective
        [
            "I've been on this side of the looking glass all morning. Bring me something to turn over.",
            "Things look backwards through the glass until you ask the right question. Try one.",
            "A mirror only shows you what you bring to it. So — what are you bringing?",
            "On the other side of the glass, the hard questions are the fun ones. Hand me one.",
            "Reflection's overrated on its own. Let's reflect on something specific.",
        ],
        // Tea / Hatter / time
        [
            "It's always tea time somewhere. Here, it's question time. Go ahead.",
            "Mad as a hatter is overrated. Sharp as one — now we're talking.",
            "No tea yet, but I've got time and a working brain. What are we untangling?",
            "The Hatter argues with time. I'd rather use it. What's first?",
            "Pull up a chair. The table's long and I'm only mildly enigmatic before tea.",
        ],
        // Cheshire / wit
        [
            "The Cheshire Cat grins and vanishes. I'd rather stay and actually answer things.",
            "I can keep looking enigmatic, or you can ask me something. Your call.",
            "All the best cats disappear. I'm the one that sticks around to help.",
            "A grin with no answer is just decoration. Ask, and I'll bring both.",
            "We're all a little mad here. Some of us are also genuinely useful.",
        ],
        // Impossible things / getting started
        [
            "Six impossible things before breakfast? Let's start with one real one.",
            "Curiouser and curiouser is my favorite state. What's yours?",
            "Begin at the beginning, the King said. Decent advice. What's the beginning?",
            "Pick a thread. I'll help you pull it all the way through.",
            "The map's only useful once you start walking. What's the first question?",
        ],
    ]
}
