import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import ExteraPreferences
import ExteraResources
import ExteraProxySearch

private final class ExteraProxyArguments {
    let connect: (ExteraProxyCandidate) -> Void
    init(connect: @escaping (ExteraProxyCandidate) -> Void) {
        self.connect = connect
    }
}

private struct ProxySearchState {
    var candidates: [ExteraProxyCandidate] = []
    var validations: [String: ExteraProxyValidation] = [:]
    var searching = false
}

/// Applies a validated proxy candidate to the app's proxy settings,
/// making it the active server and enabling the proxy.
private func connectProxyCandidate(context: AccountContext, candidate: ExteraProxyCandidate) {
    guard let secretData = candidate.secretHex.hexData else { return }
    let server = ProxyServerSettings(host: candidate.host, port: candidate.port, connection: .mtp(secret: secretData))
    let _ = updateProxySettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
        var current = current
        if !current.servers.contains(server) {
            current.servers.append(server)
        }
        current.activeServer = server
        current.enabled = true
        return current
    }).start()
}

private extension String {
    var hexData: Data? {
        let chars = Array(self)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}

/// Proxy search screen: fetches public MTProto proxy lists, validates each
/// candidate with a TCP ping, and connects the chosen proxy through the
/// app's proxy settings.
func exteraProxySearchController(context: AccountContext) -> ViewController {
    let state = Atomic<ProxySearchState>(value: ProxySearchState())
    let statePromise = ValuePromise<ProxySearchState>(state.with { $0 })
    let searchTask = Atomic<Task<Void, Never>?>(value: nil)

    func beginSearch() {
        statePromise.set(state.with { current in
            var updated = current
            updated.searching = true
            updated.candidates = []
            updated.validations = [:]
            return updated
        })
        let task = Task { @MainActor in
            do {
                let candidates = try await ExteraProxyListFetcher.shared.fetchAll()
                let sorted = candidates.sorted { $0.host < $1.host }
                statePromise.set(state.with { current in
                    var updated = current
                    updated.candidates = sorted
                    for candidate in sorted {
                        updated.validations[candidate.id] = ExteraProxyValidation(candidateId: candidate.id, state: .pending)
                    }
                    return updated
                })
                let stream = await ExteraProxyValidator.shared.validateAll(candidates: sorted, concurrency: 6)
                for await validation in stream {
                    if Task.isCancelled { break }
                    statePromise.set(state.with { current in
                        var updated = current
                        updated.validations[validation.candidateId] = validation
                        return updated
                    })
                }
            } catch {
                // A network failure keeps the previous list; the state resets below.
            }
            statePromise.set(state.with { current in
                var updated = current
                updated.searching = false
                return updated
            })
        }
        _ = searchTask.swap(task)
    }

    let arguments = ExteraProxyArguments(connect: { candidate in
        connectProxyCandidate(context: context, candidate: candidate)
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, ExteraProxyArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modLoc("ModProxyListTitle", languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: ItemListNavigationButton(
                content: .text(state.searching ? modLoc("ModProxySearchStop", languageCode) : modLoc("ModProxySearchAction", languageCode)),
                style: .regular,
                enabled: true,
                action: {
                    if state.searching {
                        searchTask.with { task in
                            task?.cancel()
                        }
                        statePromise.set(state.with { current in
                            var updated = current
                            updated.searching = false
                            return updated
                        })
                    } else {
                        beginSearch()
                    }
                }
            ),
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries: [ExteraModSimpleEntry] = []
        var stableId: Int32 = 0
        if state.candidates.isEmpty {
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .info(state.searching ? modLoc("ModProxySearchChecking", languageCode) : modLoc("ModProxySearchEmpty", languageCode))))
            stableId += 1
        } else {
            let working = state.validations.values.filter { $0.state == .reachable }.count
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .info(String(format: modLoc("ModProxyListFetched", languageCode), state.candidates.count, working))))
            stableId += 1
            let reachableFirst = state.candidates.sorted { a, b in
                let aReachable = state.validations[a.id]?.state == .reachable
                let bReachable = state.validations[b.id]?.state == .reachable
                if aReachable != bReachable { return aReachable }
                return (state.validations[a.id]?.pingMilliseconds ?? .infinity) < (state.validations[b.id]?.pingMilliseconds ?? .infinity)
            }
            for candidate in reachableFirst.prefix(80) {
                entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .proxy(candidate: candidate, validation: state.validations[candidate.id] ?? ExteraProxyValidation(candidateId: candidate.id, state: .pending))))
                stableId += 1
            }
        }
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (list, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    return controller
}
