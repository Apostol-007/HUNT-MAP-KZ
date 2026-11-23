import SwiftUI
import PDFKit

/// Offline, original source documents. The app never rewrites statutory wording.
struct LegalDocument: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let topic: String
    let pages: Int
    let symbol: String

    static let all: [LegalDocument] = [
        .init(id: "approval-hunting-rules", title: "Правила охоты",
              subtitle: "Приказ № 18-03/157 от 27.02.2015", topic: "Охота",
              pages: 20, symbol: "figure.walk"),
        .init(id: "approval-voucher-form-rules", title: "Путёвки: форма и выдача",
              subtitle: "Приказ № 18-03/145 от 27.02.2015", topic: "Документы",
              pages: 8, symbol: "doc.text"),
        .init(id: "wildlife-protection", title: "Охрана животного мира",
              subtitle: "Закон РК № 593 от 09.07.2004", topic: "Законодательство",
              pages: 94, symbol: "leaf"),
        .init(id: "rules-civil-service-weapons", title: "Правила оборота оружия",
              subtitle: "Приказ МВД № 602 от 01.07.2019", topic: "Оружие",
              pages: 115, symbol: "shield.lefthalf.filled")
    ]

    var url: URL? {
        Bundle.main.url(forResource: id, withExtension: "pdf", subdirectory: "LegalDocuments")
        ?? Bundle.main.url(forResource: id, withExtension: "pdf")
    }
}
struct LegalSearchHit: Identifiable, Sendable {
    let id: String
    let documentID: String
    let page: Int
    let excerpt: String
}

struct LegalLibraryView: View {
    @State private var query = ""
    @State private var matches: [LegalSearchHit] = []
    @State private var searching = false
    @State private var hasSearched = false
    @State private var selected: LegalDocument?
    @State private var targetPage = 0
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    header
                    Text("Четыре оригинальных документа · 237 страниц · доступно без интернета")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.mint)
                        TextField("Поиск по всем документам", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { searchAll() }
                        if !query.isEmpty {
                            Button { query = ""; matches = []; hasSearched = false } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    if searching {
                        Label("Ищем по страницам…", systemImage: "text.magnifyingglass")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView().tint(.mint)
                    }
                    if hasSearched && !searching {
                        Text(matches.isEmpty ? "По вашему запросу ничего не найдено" : "Найдено: \(matches.count) совпадений")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(matches) { hit in
                            if let item = LegalDocument.all.first(where: { $0.id == hit.documentID }) {
                                Button {
                                    targetPage = hit.page
                                    selected = item
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(item.title) · страница \(hit.page + 1)")
                                            .font(.caption.bold()).foregroundStyle(.mint)
                                        Text(hit.excerpt).font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(3)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        ForEach(LegalDocument.all) { document in
                            Button {
                                targetPage = 0
                                selected = document
                            } label: { documentRow(document) }
                                .buttonStyle(.plain)
                        }
                    }
                    Label("Тексты представлены как в загруженных PDF. Проверяйте актуальность редакций нормативных актов перед использованием.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(17)
            }
            .background(Color(red: 0.045, green: 0.065, blue: 0.066).ignoresSafeArea())
            .preferredColorScheme(.dark)
            .navigationTitle("Библиотека охотника")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selected) { item in
                LegalPDFReader(document: item, initialPage: targetPage)
            }
            .onDisappear { searchTask?.cancel() }
        }
    }

    private var header: some View {
        HStack(spacing: 15) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(.mint)
                .frame(width: 58, height: 58)
                .background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 4) {
                Text("Знай свои правила").font(.title3.bold())
                Text("Охота · путёвки · природа · оружие")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func documentRow(_ doc: LegalDocument) -> some View {
        HStack(spacing: 14) {
            Image(systemName: doc.symbol)
                .font(.title3)
                .foregroundStyle(.mint)
                .frame(width: 47, height: 53)
                .background(.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(doc.title).font(.subheadline.bold()).foregroundStyle(.white)
                Text(doc.subtitle).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(doc.topic)
                    Text("\(doc.pages) стр.")
                    Label("Офлайн", systemImage: "checkmark.circle")
                }.font(.caption2).foregroundStyle(.mint.opacity(0.85))
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private func searchAll() {
        searchTask?.cancel()
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.count >= 2 else { matches = []; hasSearched = false; return }
        searching = true
        hasSearched = true
        searchTask = Task {
            let results = await Task.detached(priority: .userInitiated) {
                var hits: [LegalSearchHit] = []
                for doc in LegalDocument.all {
                    guard !Task.isCancelled, let url = doc.url, let pdf = PDFDocument(url: url) else { continue }
                    let selections = pdf.findString(search, withOptions: [.caseInsensitive])
                    for selection in selections.prefix(120) {
                        guard let page = selection.pages.first else { continue }
                        let number = pdf.index(for: page)
                        let excerpt = selection.string?.replacingOccurrences(of: "\n", with: " ") ?? search
                        hits.append(LegalSearchHit(id: "\(doc.id)-\(number)-\(hits.count)",
                                                   documentID: doc.id, page: number, excerpt: excerpt))
                    }
                }
                return hits
            }.value
            guard !Task.isCancelled else { return }
            matches = results
            searching = false
        }
    }
}

struct LegalPDFReader: View {
    let document: LegalDocument
    let initialPage: Int
    @State private var search = ""
    @State private var results: [Int] = []
    @State private var selectedPage: Int
    @State private var scale: CGFloat = 1
    @State private var showResults = false
    @State private var searchTask: Task<Void, Never>?

    init(document: LegalDocument, initialPage: Int) {
        self.document = document
        self.initialPage = initialPage
        _selectedPage = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.mint)
                TextField("Найти слово или статью", text: $search)
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                if !search.isEmpty {
                    Button { search = ""; results = []; showResults = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }.padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 14).padding(.top, 9)
            if showResults {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        if results.isEmpty { Text("Совпадений нет").font(.caption).foregroundStyle(.secondary) }
                        ForEach(results, id: \.self) { page in
                            Button("Стр. \(page + 1)") { selectedPage = page }
                                .font(.caption.bold()).padding(.vertical, 7).padding(.horizontal, 10)
                                .background(selectedPage == page ? Color.mint.opacity(0.3) : Color.white.opacity(0.09), in: Capsule())
                        }
                    }
                }.padding(.horizontal, 14).padding(.top, 8)
            }
            if let url = document.url {
                PDFKitPageView(url: url, page: selectedPage, scale: scale, term: search)
                    .id(document.id)
            } else {
                ContentUnavailableView("Файл не найден в сборке", systemImage: "doc.questionmark",
                                       description: Text("Проверьте упаковку LegalDocuments в iOS-сборке"))
            }
            HStack(spacing: 13) {
                Button { selectedPage = max(0, selectedPage - 1) } label: {
                    Image(systemName: "chevron.left")
                }.disabled(selectedPage == 0)
                Text("\(selectedPage + 1) / \(document.pages)")
                    .font(.caption.monospacedDigit()).frame(minWidth: 75)
                Button { selectedPage = min(document.pages - 1, selectedPage + 1) } label: {
                    Image(systemName: "chevron.right")
                }.disabled(selectedPage >= document.pages - 1)
                Spacer()
                Button { scale = max(0.7, scale / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button { scale = min(4, scale * 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button("100%") { scale = 1 }.font(.caption.bold())
            }
            .buttonStyle(.borderless)
            .padding(12)
            .background(Color.black.opacity(0.82))
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: search) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(430))
                guard !Task.isCancelled else { return }
                runSearch()
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func runSearch() {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count > 1, let url = document.url, let pdf = PDFDocument(url: url) else {
            results = []; showResults = false; return
        }
        var found: Set<Int> = []
        for match in pdf.findString(term, withOptions: [.caseInsensitive]) {
            if let page = match.pages.first { found.insert(pdf.index(for: page)) }
        }
        results = found.sorted()
        showResults = true
        if let first = results.first { selectedPage = first }
    }
}

private struct PDFKitPageView: UIViewRepresentable {
    let url: URL
    let page: Int
    let scale: CGFloat
    let term: String

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = UIColor.black
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.document = PDFDocument(url: url)
        context.coordinator.lastPage = -1
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard let pdf = view.document else { return }
        if page != context.coordinator.lastPage, let selected = pdf.page(at: page) {
            view.go(to: selected)
            context.coordinator.lastPage = page
        }
        if abs(context.coordinator.lastScale - scale) > 0.001 {
            if scale == 1 { view.autoScales = true }
            else {
                view.autoScales = false
                view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, scale))
            }
            context.coordinator.lastScale = scale
        }
        if context.coordinator.lastTerm != term || context.coordinator.lastHighlightPage != page {
            if term.count > 1 {
                if let hit = pdf.findString(term, withOptions: [.caseInsensitive])
                    .first(where: { $0.pages.first.map { pdf.index(for: $0) } == page }) {
                    view.setCurrentSelection(hit, animate: false)
                } else { view.clearSelection() }
            } else { view.clearSelection() }
            context.coordinator.lastTerm = term
            context.coordinator.lastHighlightPage = page
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var lastPage = -1
        var lastScale: CGFloat = 1
        var lastTerm = ""
        var lastHighlightPage = -1
    }
}
