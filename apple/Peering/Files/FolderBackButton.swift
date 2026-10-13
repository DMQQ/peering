import SwiftUI
import UIKit

/// The back button of a folder page, named for the folder above. The system button shows only a chevron here, and hiding it drops the edge swipe, which ``EdgeSwipeBack`` puts back.
struct FolderBackButton: ViewModifier {
    let path: String?
    /// The page at this folder has no parent button: the system one leaves the browser.
    var floor: String?
    let openParent: (String) -> Void

    func body(content: Content) -> some View {
        if let parent {
            content
                .navigationBarBackButtonHidden()
                .background(EdgeSwipeBack())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { openParent(parent) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left").fontWeight(.semibold)
                                Text(parent == "/" ? "/" : (parent as NSString).lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 130, alignment: .leading)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
        } else {
            content
        }
    }

    private var parent: String? {
        guard let path, path.hasPrefix("/"), path != "/", path != floor else { return nil }
        let up = (path as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }
}

/// A hidden system back button also disables the navigation controller's edge-swipe pop; this re-enables it on the controller that hosts the page.
private struct EdgeSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Resolver { Resolver() }
    func updateUIViewController(_ controller: Resolver, context: Context) {}

    final class Resolver: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let navigation = navigationController else { return }
            navigation.interactivePopGestureRecognizer?.delegate = nil
            navigation.interactivePopGestureRecognizer?.isEnabled = navigation.viewControllers.count > 1
        }
    }
}

extension View {
    func folderBackButton(of path: String?, floor: String? = nil, openParent: @escaping (String) -> Void) -> some View {
        modifier(FolderBackButton(path: path, floor: floor, openParent: openParent))
    }
}
