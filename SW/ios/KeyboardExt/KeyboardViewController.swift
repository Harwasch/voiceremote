import UIKit

final class KeyboardViewController: UIInputViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let nextKeyboard = UIButton(type: .system)
        nextKeyboard.setTitle("Next keyboard", for: .normal)
        nextKeyboard.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboard.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        view.addSubview(nextKeyboard)
        NSLayoutConstraint.activate([
            nextKeyboard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            nextKeyboard.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
    }
}
