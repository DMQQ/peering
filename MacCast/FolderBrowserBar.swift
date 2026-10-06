import SwiftUI

/// The one bottom row of every folder browser: a search field with the hidden-files switch inside it, and whatever the screen acts with (Use, new, send) beside it.
struct FolderBrowserBar<Leading: View, Actions: View>: View {
    let prompt: String
    @Binding var query: String
    @Binding var showsHidden: Bool
    var isLoading = false
    var searchFocused: FocusState<Bool>.Binding
    let leading: Leading
    let actions: Actions

    init(
        prompt: String,
        query: Binding<String>,
        showsHidden: Binding<Bool>,
        isLoading: Bool = false,
        searchFocused: FocusState<Bool>.Binding,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder actions: () -> Actions
    ) {
        self.prompt = prompt
        _query = query
        _showsHidden = showsHidden
        self.isLoading = isLoading
        self.searchFocused = searchFocused
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            InputCapsule {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(ColorPalette.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused(searchFocused)
                    .submitLabel(.done)
                    .onSubmit { searchFocused.wrappedValue = false }

                if isLoading {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the filter")
                }

                Button { showsHidden.toggle() } label: {
                    Image(systemName: showsHidden ? "eye" : "eye.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(showsHidden ? ColorPalette.accent : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsHidden ? "Hide hidden files" : "Show hidden files")
            }

            actions
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

/// The folders above this one as a menu on the navigation title, which is how Files does it: the path is a place to jump from, not a strip to read.
struct AncestorsMenu: ViewModifier {
    let path: String?
    let open: (String) -> Void

    func body(content: Content) -> some View {
        content.toolbarTitleMenu {
            ForEach(ancestors, id: \.path) { ancestor in
                Button(ancestor.title, systemImage: "folder") { open(ancestor.path) }
            }
        }
    }

    private var ancestors: [(title: String, path: String)] {
        guard let path, path.hasPrefix("/") else { return [] }
        var result: [(title: String, path: String)] = []
        var walked = ""
        for component in path.split(separator: "/").dropLast() {
            walked += "/" + component
            result.append((String(component), walked))
        }
        result.append(("/", "/"))
        return result.reversed()
    }
}

extension View {
    func ancestorsMenu(of path: String?, open: @escaping (String) -> Void) -> some View {
        modifier(AncestorsMenu(path: path, open: open))
    }
}

extension FolderBrowserBar where Leading == EmptyView {
    init(
        prompt: String,
        query: Binding<String>,
        showsHidden: Binding<Bool>,
        isLoading: Bool = false,
        searchFocused: FocusState<Bool>.Binding,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            prompt: prompt,
            query: query,
            showsHidden: showsHidden,
            isLoading: isLoading,
            searchFocused: searchFocused,
            leading: { EmptyView() },
            actions: actions
        )
    }
}
