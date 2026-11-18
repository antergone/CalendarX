//
//  CalendarScreen.swift
//  CalendarX
//
//  Created by zm on 2023/2/26.
//

import CalendarXLib
import SwiftUI
import WidgetKit

@MainActor
struct CalendarScreen: View {

    @Environment(\.locale)
    private var locale

    @Environment(\.authorizer)
    private var authorizer

    @EnvironmentObject
    private var router: Router

    @EnvironmentObject
    private var dialog: Dialog

    @EnvironmentObject
    private var calendarStore: CalendarStore

    @EnvironmentObject
    private var tiaoxiuStore: TiaoxiuStore


    var body: some View {
        VStack(spacing: 20) {
            TitleView {
                Text(L10n.Settings.calendar)
            } leftItems: {
                ScacleImageButton(image: .backward) {
                    router.pop()
                }
            } rightItems: {
                EmptyView()
            }

            Section {
                weekRow
                eventsRow
                lunarRow
                holidaysRow
                tiaoxiuRow
                weekNumbersRow
                keyboardShortcutRow
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding()
    }
}

extension CalendarScreen {

    private var weekRow: some View {
        SettingsPickerRow(
            title: L10n.Calendar.startWeekOn,
            items: AppWeekday.allCases,
            selection: calendarStore.$weekday
        ) { Text($0.symbol(locale: locale)) }
    }

    @ViewBuilder
    private var eventsRow: some View {

        let isOn = Binding {
            calendarStore.showEvents
        } set: { value in
            switch authorizer.eventsStatus {
            case .notRequested: Task { calendarStore.showEvents = await authorizer.requestEventsAuthorization() }
            case .granted: calendarStore.showEvents = value
            default:
                dialog.popup(.calendars) {
                    router.preference(Privacy.calendars)
                }
            }
        }

        Toggle(isOn: isOn) { Text(L10n.Calendar.showEvents).font(.title3) }
            .checkboxStyle()
    }

    private var lunarRow: some View {
        Toggle(isOn: calendarStore.$showLunar) { Text(L10n.Calendar.showLunar).font(.title3) }
            .checkboxStyle()
    }

    private var holidaysRow: some View {
        Toggle(isOn: calendarStore.$showHolidays) { Text(L10n.Calendar.showHolidays).font(.title3) }
            .checkboxStyle()
    }

    private var tiaoxiuRow: some View {
        SettingsRow(
            title: L10n.Calendar.tiaoxiuData,
            detail: {
                Text(tiaoxiuStore.source == .remote ? L10n.Calendar.tiaoxiuRemote : L10n.Calendar.tiaoxiuBuiltIn)
            }
        ) {
            router.push(.tiaoxiuData)
        }
    }

    private var weekNumbersRow: some View {
        Toggle(isOn: calendarStore.$showWeekNumbers) { Text(L10n.Calendar.showWeekNumbers).font(.title3) }
            .checkboxStyle()
    }
    
    private var keyboardShortcutRow: some View {
        Toggle(isOn: calendarStore.$keyboardShortcut) {
            HStack {
                Text(L10n.Calendar.keyboardShortcut).font(.title3)
                ScacleImageButton(image: .tips) {
                    dialog.popup(.shortcut)
                }
            }
        }
        .checkboxStyle()
    }
}

@MainActor
struct TiaoxiuDataScreen: View {

    @Environment(\.locale)
    private var locale

    @EnvironmentObject
    private var router: Router

    @EnvironmentObject
    private var tiaoxiuStore: TiaoxiuStore

    @State
    private var message: LocalizedStringKey?

    @State
    private var showsErrorMessage = false

    var body: some View {
        VStack(spacing: 12) {
            TitleView {
                Text(L10n.Calendar.tiaoxiuData)
            } leftItems: {
                ScacleImageButton(image: .backward) {
                    router.pop()
                }
            } rightItems: {
                EmptyView()
            }

            Section {
                sourceRow
                yearsRow
                lastUpdatedRow
                remoteURLRow
                if tiaoxiuStore.source == .remote {
                    bundledRow
                }
            }

            ScacleCapsuleButton(
                title: tiaoxiuStore.isUpdating
                    ? L10n.Calendar.tiaoxiuUpdating
                    : L10n.Calendar.tiaoxiuUpdate,
                foregroundColor: .appWhite,
                backgroundColor: .accentColor
            ) {
                update()
            }
            .disabled(tiaoxiuStore.isUpdating)

            if let message {
                Text(message)
                    .font(.caption)
                    .appForeground(showsErrorMessage ? .accentColor : .appSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding()
    }
}

extension TiaoxiuDataScreen {

    private var sourceRow: some View {
        SettingsRow(
            title: L10n.Calendar.tiaoxiuSource,
            showArrow: false,
            detail: {
                Text(tiaoxiuStore.source == .remote ? L10n.Calendar.tiaoxiuRemote : L10n.Calendar.tiaoxiuBuiltIn)
            },
            action: {}
        )
    }

    private var yearsRow: some View {
        SettingsRow(
            title: L10n.Calendar.tiaoxiuYears,
            showArrow: false,
            detail: {
                Text(yearsText)
            },
            action: {}
        )
    }

    private var lastUpdatedRow: some View {
        SettingsRow(
            title: L10n.Calendar.tiaoxiuLastUpdated,
            showArrow: false,
            detail: {
                lastUpdatedText
            },
            action: {}
        )
    }

    private var remoteURLRow: some View {
        SettingsRow(
            title: L10n.Calendar.tiaoxiuRemoteAddress,
            detail: {
                Text(tiaoxiuStore.remoteURL.host ?? tiaoxiuStore.remoteURL.absoluteString)
            }
        ) {
            router.push(.tiaoxiuRemoteURL)
        }
    }

    private var bundledRow: some View {
        SettingsRow(
            title: L10n.Calendar.tiaoxiuRestoreBundled,
            showArrow: false,
            detail: {
                EmptyView()
            }
        ) {
            let restored = tiaoxiuStore.restoreBundledData()
            message = restored
                ? L10n.Calendar.tiaoxiuRestoredBundled
                : L10n.Calendar.tiaoxiuStorageError
            showsErrorMessage = !restored
        }
    }

    private var lastUpdatedText: Text {
        guard let lastUpdated = tiaoxiuStore.lastUpdated else {
            return Text(L10n.Calendar.tiaoxiuNeverUpdated)
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return Text(formatter.string(from: lastUpdated))
    }

    private var yearsText: String {
        guard let first = tiaoxiuStore.years.first,
            let last = tiaoxiuStore.years.last
        else {
            return "-"
        }
        return first == last ? "\(first)" : "\(first)–\(last)"
    }

    private func update() {
        Task {
            let result = await tiaoxiuStore.update()

            switch result {
            case .success(.updated):
                message = L10n.Calendar.tiaoxiuUpdated
                showsErrorMessage = false
                WidgetCenter.shared.reloadAllTimelines()
            case .success(.unchanged):
                message = L10n.Calendar.tiaoxiuUnchanged
                showsErrorMessage = false
            case .failure(let error):
                message = message(for: error)
                showsErrorMessage = true
            }
        }
    }

    private func message(for error: TiaoxiuUpdateError) -> LocalizedStringKey {
        switch error {
        case .invalidData, .payloadTooLarge:
            L10n.Calendar.tiaoxiuInvalidData
        case .storage:
            L10n.Calendar.tiaoxiuStorageError
        case .server, .invalidResponse:
            L10n.Calendar.tiaoxiuServerError
        case .network, .updateInProgress:
            L10n.Calendar.tiaoxiuNetworkError
        }
    }
}

@MainActor
struct TiaoxiuRemoteURLScreen: View {

    @EnvironmentObject
    private var router: Router

    @EnvironmentObject
    private var tiaoxiuStore: TiaoxiuStore

    @State
    private var urlText = ""

    @State
    private var message: LocalizedStringKey?

    @State
    private var showsErrorMessage = false

    @State
    private var hasLoadedURL = false

    var body: some View {
        VStack(spacing: 12) {
            TitleView {
                Text(L10n.Calendar.tiaoxiuRemoteAddress)
            } leftItems: {
                ScacleImageButton(image: .backward) {
                    router.pop()
                }
            } rightItems: {
                EmptyView()
            }

            TextField("https://example.com/festival_solar_tiaoxiu.json", text: $urlText)
                .textFieldStyle(.roundedBorder)

            Text(L10n.Calendar.tiaoxiuRemoteAddressHint)
                .font(.caption)
                .appForeground(.appSecondary)
                .multilineTextAlignment(.center)

            ScacleCapsuleButton(
                title: L10n.Calendar.tiaoxiuSaveAddress,
                foregroundColor: .appWhite,
                backgroundColor: .accentColor
            ) {
                save()
            }

            ScacleCapsuleButton(
                title: L10n.Calendar.tiaoxiuDefaultAddress,
                foregroundColor: .appPrimary,
                backgroundColor: .card
            ) {
                tiaoxiuStore.resetRemoteURL()
                urlText = tiaoxiuStore.remoteURL.absoluteString
                message = L10n.Calendar.tiaoxiuAddressSaved
                showsErrorMessage = false
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .appForeground(showsErrorMessage ? .accentColor : .appSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding()
        .onAppear {
            guard !hasLoadedURL else { return }
            urlText = tiaoxiuStore.remoteURL.absoluteString
            hasLoadedURL = true
        }
    }
}

extension TiaoxiuRemoteURLScreen {

    private func save() {
        guard tiaoxiuStore.setRemoteURL(urlText) else {
            message = L10n.Calendar.tiaoxiuAddressInvalid
            showsErrorMessage = true
            return
        }

        urlText = tiaoxiuStore.remoteURL.absoluteString
        message = L10n.Calendar.tiaoxiuAddressSaved
        showsErrorMessage = false
    }
}
