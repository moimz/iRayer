import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 폴더 설정 (추가·편집 같은 화면): 이름·아이콘·경로, 보기, 홈·검색에 표시, 성인 등급 숨기기 중 숨김.
/// 추가한 폴더에만 두고 그 하위 폴더는 모두 따른다. 추가는 [추가] 를 눌러야 만들고, 편집은 바꾸는 즉시 저장한다 (라이브러리 설정처럼).
/// 정렬은 폴더마다 도구 막대의 정렬 단추에서.
struct FolderSettingsView: View {
    enum Target: Identifiable {
        case edit(AddedFolder)
        /// 이 기기의 폴더 추가
        case newLocal(URL)
        /// 저장소 안 폴더 추가
        case newStorage(NetworkServer, URL)

        var id: String {
            switch self {
            case .edit(let added): "e" + added.id
            case .newLocal(let url): "nl" + url.absoluteString
            case .newStorage(let server, let url): "ns" + server.id.uuidString + url.absoluteString
            }
        }
    }

    /// 편집을 띄우는 곳: 시트 (설정·아이폰·아이패드 폴더 화면), 맥 폴더 화면의 옆 패널
    enum Presentation {
        case sheet, panel
    }

    let target: Target
    var presentation = Presentation.sheet

    @Environment(\.dismiss) private var dismiss
    @State private var options = FolderOptionsStore.shared
    @State private var locations = LocationStore.shared
    @State private var name = ""
    @State private var icon: String?
    /// 추가: [추가] 를 누를 때 적을 설정
    @State private var draft = FolderOptions(url: URL(filePath: "/"))
    /// 편집: 읽어 들인 뒤에만 이름·아이콘을 저장한다
    @State private var loaded = false
    /// 성인 등급 숨기기 중에 "숨김"을 끄려면 PIN 을 묻는다
    @State private var askingPIN = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isNew {
                FormSheet(title: "폴더 추가", confirmTitle: "추가", macSize: CGSize(width: 520, height: 640), onConfirm: add) {
                    sections
                }
            } else {
                editBody
                    // 이름은 잠깐 뒤에 저장 (칠 때마다 iCloud 로 보내지 않게)
                    .task(id: NameAndIcon(name: name, icon: icon)) {
                        guard loaded else { return }
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        saveNameAndIcon()
                    }
                    .onDisappear(perform: saveNameAndIcon)
            }
        }
        .onAppear(perform: load)
        #if os(iOS)
        // 바뀜 (2026-11-12, 사용자): 아이폰·아이패드는 앱 잠금과 같은 숫자 자판
        .onChange(of: askingPIN) { _, asking in
            guard asking else { return }
            askingPIN = false
            AppLock.shared.askPIN(title: "PIN 입력", creating: false, length: AdultFilter.shared.pinLength) { pin in
                guard AdultFilter.shared.check(pin) else { return false }
                settings.wrappedValue.hidesForAdult = false
                return true
            }
        }
        #else
        .sheet(isPresented: $askingPIN) {
            PINSheet(purpose: .verify) { pin in
                guard AdultFilter.shared.check(pin) else { return false }
                settings.wrappedValue.hidesForAdult = false
                return true
            }
        }
        #endif
    }

    /// 편집: 맥 옆 패널은 내용만, 시트는 [완료] (닫기만, 이미 저장돼 있다)
    @ViewBuilder
    private var editBody: some View {
        #if os(macOS)
        if presentation == .panel {
            Form { sections }
                .formStyle(.grouped)
        } else {
            VStack(spacing: 0) {
                Form { sections }
                    .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("완료") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(width: 520, height: 640)
        }
        #else
        NavigationStack {
            Form { sections }
                .navigationTitle(defaultName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        if isThisDevice {
            Section {
                LabeledContent("경로") { pathText }
            }
        } else {
            Section {
                TextField("이름", text: $name, prompt: Text(defaultName))
                LabeledContent("경로") { pathText }
            } footer: {
                Text("사이드바·바로가기에 이 이름으로 보입니다.")
            }
            Section("아이콘") {
                IconPicker(selection: $icon, defaultSymbol: "folder")
            }
        }

        Section {
            ViewModePicker(selection: settings.viewMode)
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        } header: {
            Text("보기")
        } footer: {
            Text("자동은 폴더마다 압축 파일이 영상보다 많으면 포스터로 보여줍니다. 하위 폴더도 모두 이 보기를 따릅니다.")
        }

        Section {
            Toggle(isOn: flag(\.showsOnHome)) {
                Label("홈에 표시", systemImage: "house")
            }
            Toggle(isOn: flag(\.showsInSearch)) {
                Label("검색에 표시", systemImage: "magnifyingglass")
            }
        } footer: {
            Text("하위 폴더도 모두 따릅니다. 홈·검색에 표시를 켜면 이 폴더를 훑어 둡니다.")
        }

        Section {
            Toggle(isOn: Binding(
                get: { settings.wrappedValue.hidesForAdult ?? false },
                set: { on in
                    // 숨기는 것은 그냥, 숨김을 푸는 것은 성인 등급 숨기기 중이면 PIN 을 묻는다 (추가할 때는 아직 숨긴 게 없다)
                    if !on, !isNew, AdultFilter.shared.isOn { askingPIN = true } else { settings.wrappedValue.hidesForAdult = on }
                }
            )) {
                Label("성인 등급 숨기기 중에는 숨김", systemImage: "eye.slash")
            }
        } footer: {
            Text("설정 → 성인 등급 숨기기를 켜면 이 폴더(하위 폴더 포함)를 사이드바·바로가기·홈·검색에서 숨깁니다.")
        }

        if let errorMessage {
            Section { Text(errorMessage).foregroundStyle(.red) }
        }
    }

    private var pathText: some View {
        Text(path).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
    }

    // MARK: - 대상

    private var isNew: Bool {
        if case .edit = target { return false }
        return true
    }

    private var isThisDevice: Bool {
        if case .edit(.thisDevice) = target { return true }
        return false
    }

    /// 편집하는 폴더 (이름·아이콘을 바꾼 뒤의 것, 지웠으면 nil)
    private var added: AddedFolder? {
        if case .edit(let added) = target { return locations.refreshed(added) }
        return nil
    }

    /// 설정을 둘 폴더 주소
    private var url: URL? {
        switch target {
        case .edit: added.flatMap(locations.url(of:))
        case .newLocal(let url): url
        case .newStorage(_, let url): url
        }
    }

    private var serverID: UUID? {
        switch target {
        case .edit(let added): added.serverID
        case .newLocal: nil
        case .newStorage(let server, _): server.id
        }
    }

    private var defaultName: String {
        switch target {
        case .edit(let added): (self.added ?? added).name
        case .newLocal(let url): url.lastPathComponent
        case .newStorage(let server, let url):
            url.lastPathComponent.precomposedStringWithCanonicalMapping.isEmpty ? server.name : url.lastPathComponent.precomposedStringWithCanonicalMapping
        }
    }

    private var path: String {
        switch target {
        case .newStorage(let server, let url):
            return "\(server.name)/\(ServerFavorite(serverID: server.id, url: url, name: "").path(in: server))"
        case .edit(.favorite(let favorite)):
            guard let server = locations.servers.first(where: { $0.id == favorite.serverID }) else { return favorite.name }
            return "\(server.name)/\(favorite.path(in: server))"
        default:
            return url?.path(percentEncoded: false) ?? defaultName
        }
    }

    // MARK: - 설정

    /// 추가는 적어 둔 것, 편집은 저장소의 것 (바꾸면 바로 저장)
    private var settings: Binding<FolderOptions> {
        guard !isNew, let url else { return $draft }
        let serverID = serverID
        return Binding(
            get: { options.explicit(url, serverID: serverID) ?? FolderOptions(url: url, serverID: serverID) },
            set: { new in
                let old = options.explicit(url, serverID: serverID)
                options.update(url, serverID: serverID) { $0 = new }
                Self.applied(old: old, new: new)
            }
        )
    }

    private func flag(_ keyPath: WritableKeyPath<FolderOptions, Bool?>) -> Binding<Bool> {
        Binding(get: { settings.wrappedValue[keyPath: keyPath] ?? false },
                set: { settings.wrappedValue[keyPath: keyPath] = $0 })
    }

    /// 바뀐 설정을 화면·홈·검색에 반영한다
    private static func applied(old: FolderOptions?, new: FolderOptions) {
        if old?.showsOnHome != new.showsOnHome || old?.showsInSearch != new.showsInSearch {
            Task { await MediaIndex.shared.refresh() }
        }
        if (old?.hidesForAdult ?? false) != (new.hidesForAdult ?? false) {
            LibraryScanner.shared.refreshViews()
        }
    }

    private struct NameAndIcon: Equatable {
        let name: String
        let icon: String?
    }

    private func load() {
        guard !loaded else { return }
        name = defaultName
        if let added { icon = added.icon }
        loaded = true
    }

    /// 편집: 이름·아이콘이 바뀌었으면 저장 (이름을 비우면 그대로)
    private func saveNameAndIcon() {
        guard loaded, let added, !isThisDevice else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let newName = trimmed.isEmpty ? added.name : trimmed
        guard newName != added.name || icon != added.icon else { return }
        locations.update(added, name: newName, icon: icon)
    }

    /// 추가: 폴더를 넣고 정한 설정을 적는다
    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? defaultName : trimmed
        let root: URL
        switch target {
        case .edit: return
        case .newLocal(let url):
            do {
                let folder = try locations.addFolder(url, name: finalName, icon: icon)
                root = locations.resolve(folder) ?? url
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        case .newStorage(let server, let url):
            locations.addFavorite(url, name: finalName, icon: icon, serverID: server.id)
            root = url
        }
        let draft = draft
        if draft.viewMode != nil || draft.showsOnHome != nil || draft.showsInSearch != nil || draft.hidesForAdult != nil {
            let old = options.explicit(root, serverID: serverID)
            options.update(root, serverID: serverID) {
                $0.viewMode = draft.viewMode
                $0.showsOnHome = draft.showsOnHome
                $0.showsInSearch = draft.showsInSearch
                $0.hidesForAdult = draft.hidesForAdult
            }
            Self.applied(old: old, new: options.explicit(root, serverID: serverID) ?? draft)
        }
        dismiss()
    }
}

/// 보기 방식 고르기: 자동 / 포스터 / 썸네일 (아이콘 + 이름)
private struct ViewModePicker: View {
    @Binding var selection: FolderViewMode?

    var body: some View {
        #if os(macOS)
        // 맥은 가로를 꽉 채운 분할 버튼
        FillSegmentedPicker(options: [
            ("자동", nil),
            ("포스터", .poster),
            ("썸네일", .thumbnail),
        ], selection: $selection)
        #else
        HStack(spacing: 8) {
            option(nil, title: "자동", systemImage: "wand.and.stars")
            option(.poster, title: "포스터", systemImage: "rectangle.portrait")
            option(.thumbnail, title: "썸네일", systemImage: "rectangle")
        }
        #endif
    }

    private func option(_ mode: FolderViewMode?, title: String, systemImage: String) -> some View {
        ChoiceButton(title: title, systemImage: systemImage, selected: selection == mode) { selection = mode }
    }
}

#if os(macOS)
/// 맥 분할 버튼: 가로를 꽉 채우고 칸을 고르게 나눈다 (시스템 설정처럼).
/// SwiftUI 의 분할 Picker 는 맥에서 글자 폭만큼만 차지해서 AppKit 것을 쓴다.
struct FillSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    var controlSize: NSControl.ControlSize = .large

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: options.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.controlSize = controlSize
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.segmentCount = options.count
        for (index, option) in options.enumerated() { control.setLabel(option.title, forSegment: index) }
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: FillSegmentedPicker

        init(parent: FillSegmentedPicker) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment].value
        }
    }
}
#endif

/// 아이콘 + 이름 칸 (고른 것은 강조색)
private struct ChoiceButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
