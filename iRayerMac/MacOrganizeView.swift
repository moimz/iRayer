import SwiftUI

/// 폴더 정리: 에이전트가 정한 위치와 다른 파일 목록을 보여주고, 확인하면 옮긴다
struct MacOrganizeView: View {
    let library: LibraryRecord
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var moves: [LibraryOrganizer.Move]?
    @State private var done = 0
    @State private var running = false
    @State private var failures: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("폴더 정리").font(.title2.bold())
                Text("에이전트가 정한 위치(제목 (연도)/…, 시즌 폴더 …)와 다른 파일을 옮깁니다. 같은 이름의 자막도 함께 옮깁니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            Group {
                if let moves {
                    if moves.isEmpty {
                        ContentUnavailableView("정리할 파일이 없습니다", systemImage: "checkmark.circle",
                                               description: Text("모든 파일이 정한 위치에 있습니다."))
                            // 바뀜 (2026-11-29, 사용자: 한쪽으로 쏠림): 바깥 VStack 이 leading 이라 폭을 채워 가운데로
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(moves) { move in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(move.file.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Label(move.to, systemImage: "arrow.turn.down.right").font(.callout).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                } else {
                    ProgressView("옮길 파일을 찾는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            if !failures.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: 90)
            }
            Divider()
            HStack {
                if running, let moves {
                    ProgressView(value: Double(done), total: Double(moves.count)).frame(width: 200)
                    Text("\(done)/\(moves.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button(running ? "닫기" : "취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running && done < (moves?.count ?? 0))
                if let moves, !moves.isEmpty, !running {
                    Button("\(moves.count)개 옮기기") { Task { await apply(moves) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 640, height: 520)
        .task { moves = await LibraryOrganizer.collect(library) }
    }

    private func apply(_ moves: [LibraryOrganizer.Move]) async {
        running = true
        await LibraryOrganizer.apply(moves, in: library) { count, failure in
            done = count
            if let failure { failures.append(failure) }
        }
        onDone()
    }
}
