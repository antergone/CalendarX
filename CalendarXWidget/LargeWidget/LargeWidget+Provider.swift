import CalendarXLib
import WidgetKit

extension LargeWidget {
    typealias Intent = WidgetConfigurationIntent

    @MainActor
    struct Provider: @preconcurrency IntentTimelineProvider {
        func placeholder(in context: Context) -> Entry {
            .init()
        }

        func getSnapshot(for configuration: Intent, in context: Context, completion: @escaping (Entry) -> Void) {
            completion(.init(configuration: configuration))
        }

        func getTimeline(for configuration: Intent, in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            Task { @MainActor in
                let useRemoteData = configuration.useRemoteTiaoxiuData?.boolValue ?? true
                let configuredURL = configuration.remoteURL?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let remoteURL =
                    configuredURL.flatMap { $0.isEmpty ? nil : $0 }
                    ?? TiaoxiuStore.defaultRemoteURL.absoluteString

                if useRemoteData,
                    TiaoxiuStore.shared.setRemoteURL(remoteURL)
                {
                    _ = await TiaoxiuStore.shared.update()
                } else {
                    _ = TiaoxiuStore.shared.restoreBundledData()
                }

                let date = Date()

                if #available(macOSApplicationExtension 14.0, *), date.canUpdateDate {
                    Store.today()
                }

                let entry =
                    if #available(macOSApplicationExtension 14.0, *) {
                        Entry(date: Store.date, configuration: configuration)
                    } else {
                        Entry(date: date, configuration: configuration)
                    }
                let timeline = Timeline(
                    entries: [entry],
                    policy: .after(date.startOfTomorrow)
                )
                completion(timeline)
                }
        }
    }
}

@MainActor
extension Date {
    var canUpdateDate: Bool {
        t(use24h: true, showSeconds: false) == "00:00"
    }
}
