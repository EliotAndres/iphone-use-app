import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AgentWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
    }
}

struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Agent", systemImage: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusText(context: context)
                        .font(.caption.bold())
                    StopButton(context: context)
                }
                Text(context.attributes.prompt)
                    .font(.headline)
                    .lineLimit(2)
                Text(context.state.line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Agent", systemImage: "sparkles")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack {
                        StatusText(context: context)
                            .font(.headline)
                        StopButton(context: context)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.prompt)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(context.state.line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "sparkles")
            } compactTrailing: {
                Text(context.state.running ? "\(context.state.step)" : "✓")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "sparkles")
            }
        }
    }
}

private struct StatusText: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        if context.state.running {
            Text("Step \(context.state.step)")
                .monospacedDigit()
        } else {
            Text("Finished")
        }
    }
}

private struct StopButton: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        if context.state.running {
            Button(intent: StopAgentIntent()) {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .accessibilityLabel("Stop agent")
        }
    }
}
