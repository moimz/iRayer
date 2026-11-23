import SwiftUI
import UniformTypeIdentifiers

/// 설정에서 띄우는 입력 시트: 맥은 아래쪽에 [취소] [확인] 단추, 아이폰·아이패드는 내비게이션 막대에 둔다
struct FormSheet<Content: View>: View {
    let title: String
    let confirmTitle: String
    var confirmDisabled = false
    var working = false
    var macSize = CGSize(width: 460, height: 0)
    let onConfirm: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Form { content() }
                .formStyle(.grouped)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmDisabled || working)
            }
            .padding()
        }
        .frame(width: macSize.width, height: macSize.height > 0 ? macSize.height : nil)
        #else
        NavigationStack {
            Form { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("취소", systemImage: "xmark", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if working {
                            ProgressView()
                        } else {
                            Button(confirmTitle, systemImage: "checkmark", action: onConfirm)
                                .disabled(confirmDisabled)
                        }
                    }
                }
        }
        #endif
    }
}

/// 설정 목록 맨 끝의 추가 줄 ("+ 저장소 추가"). 맥·아이폰·아이패드 같게 (1.0 처럼 구역 맨 아래).
struct SettingsAddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        SettingsActionButton(title: title, systemImage: "plus", action: action)
    }
}

/// 설정 목록의 동작 줄 (다시 훑기 등): 추가 줄과 같은 모양, 줄 전체를 누른다
struct SettingsActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsAddLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

/// 추가 줄의 모양: 강조색 + 와 이름 (아이폰 설정의 추가 줄처럼), 줄 전체를 누를 수 있게
private struct SettingsAddLabel: View {
    let title: String
    var systemImage = "plus"
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).frame(width: 22)
            Text(title)
            Spacer()
        }
        .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .contentShape(.rect)
    }
}

/// 추가할 것이 여럿일 때의 추가 줄 (메뉴)
struct SettingsAddMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            SettingsAddLabel(title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// 설정 목록의 한 줄: 아이콘 + 이름 (+ 순서를 바꿀 수 있으면 끝에 ≡). 설명 줄은 두지 않는다 (편집 화면에서 본다).
struct SettingsRow: View {
    let title: String
    let icon: String
    /// 끌어서 순서를 바꿀 수 있는 줄
    var movable = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            if movable {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .help("끌어서 순서 바꾸기")
            }
        }
        .contentShape(.rect)
    }
}

extension View {
    /// 설정 목록의 줄: 누르면 편집, 길게 누르기(맥은 오른쪽 클릭)에 편집·삭제, 아이폰·아이패드는 밀어서 삭제
    func settingsRowActions(edit: (() -> Void)?, remove: (() -> Void)?) -> some View {
        Button { edit?() } label: { self }
            .buttonStyle(.plain)
            .disabled(edit == nil)
            .contextMenu {
                if let edit { Button("편집", systemImage: "pencil", action: edit) }
                if let remove { Button("삭제", systemImage: "trash", role: .destructive, action: remove) }
            }
            #if os(iOS)
            .swipeActions {
                if let remove {
                    Button("삭제", role: .destructive, action: remove)
                }
            }
            #endif
    }
}

// MARK: - 맥: 끌어서 순서 바꾸기

extension View {
    /// 맥 설정 목록 줄을 끌어서 순서 바꾸기 (맥의 묶음 Form 은 onMove 끌기를 지원하지 않는다. 아이폰·아이패드는 onMove 로 된다).
    /// 끄는 동안 지나가는 줄과 자리를 바꾼다.
    func settingsReorder<ID: Hashable>(_ id: ID, in ids: [ID], move: @escaping (IndexSet, Int) -> Void) -> some View {
        #if os(macOS)
        onDrag {
            SettingsDrag.current = id
            return NSItemProvider(object: String(describing: id) as NSString)
        }
        .onDrop(of: [.text], delegate: SettingsDropDelegate(id: id, ids: ids, move: move))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// 지금 끌고 있는 줄
private enum SettingsDrag {
    static var current: AnyHashable?
}

private struct SettingsDropDelegate<ID: Hashable>: DropDelegate {
    let id: ID
    let ids: [ID]
    let move: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = SettingsDrag.current?.base as? ID, dragged != id,
              let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: id) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { move(IndexSet(integer: from), to > from ? to + 1 : to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        SettingsDrag.current = nil
        return true
    }
}
#endif
