import CarPlay
import UIKit

/// The CarPlay screen: a grid of big animal buttons. One tap saves a report
/// at the car's current location. A confirmation shows, then closes by itself
/// so the driver never needs a second tap.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        LocationProvider.shared.setCarPlayActive(true)
        interfaceController.setRootTemplate(makeGrid(), animated: false, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        LocationProvider.shared.setCarPlayActive(false)
    }

    /// Seven common animals plus "More animals". One tap reports.
    private func makeGrid() -> CPGridTemplate {
        var buttons = Species.carPlayQuickPicks.map { species in
            CPGridButton(titleVariants: [species.displayName],
                         image: UIImage(systemName: species.symbol) ?? UIImage()) { [weak self] _ in
                self?.handleTap(species)
            }
        }
        buttons.append(
            CPGridButton(titleVariants: ["More animals", "More"],
                         image: UIImage(systemName: "ellipsis.circle.fill") ?? UIImage()) { [weak self] _ in
                self?.showAllAnimals()
            }
        )
        return CPGridTemplate(title: "Animal on road", gridButtons: buttons)
    }

    /// Every other animal, grouped. Tapping one reports it and returns to the grid.
    private func showAllAnimals() {
        let quick = Set(Species.carPlayQuickPicks)
        let sections = Species.Group.allCases.compactMap { group -> CPListSection? in
            let items = Species.allCases
                .filter { $0.group == group && !quick.contains($0) }
                .map { species -> CPListItem in
                    let item = CPListItem(text: species.displayName, detailText: nil,
                                          image: UIImage(systemName: species.symbol))
                    item.handler = { [weak self] _, completion in
                        self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                        self?.handleTap(species)
                        completion()
                    }
                    return item
                }
            return items.isEmpty ? nil : CPListSection(items: items, header: group.rawValue, sectionIndexTitle: nil)
        }
        let list = CPListTemplate(title: "More animals", sections: sections)
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    private func handleTap(_ species: Species) {
        Task { @MainActor in
            let outcome = await ReportService.shared.report(species, source: .carplay)
            switch outcome {
            case .saved:
                showConfirmation("\(species.displayName) reported. Thank you.")
            case .duplicate:
                showConfirmation("Already reported.")
            case .failed(let reason):
                showConfirmation(reason)
            }
        }
    }

    private func showConfirmation(_ message: String) {
        guard let controller = interfaceController else { return }
        if controller.presentedTemplate != nil {
            controller.dismissTemplate(animated: false, completion: nil)
        }

        let ok = CPAlertAction(title: "OK", style: .default) { [weak controller] _ in
            controller?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [ok])
        controller.presentTemplate(alert, animated: true, completion: nil)

        Task { @MainActor [weak controller] in
            try? await Task.sleep(for: .seconds(3))
            guard let controller, controller.presentedTemplate === alert else { return }
            controller.dismissTemplate(animated: true, completion: nil)
        }
    }
}
