//
//  FeedTabView.swift
//  Brief
//
//  Discover feed screen with tab filter pills, search, pull-to-refresh, and infinite scroll.
//

import SwiftUI

struct FeedTabView: View {
    @Bindable var viewModel: FeedTabViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabFilterBar

                if !viewModel.query.trimmedSearchText.isEmpty {
                    searchSortBar
                }

                if let refreshError = viewModel.refreshErrorMessage {
                    ErrorBanner(message: refreshError, retryTitle: "Retry") {
                        Task {
                            await viewModel.refresh()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                contentView
            }
            .navigationTitle("Brief")
            .searchable(
                text: Binding(
                    get: { viewModel.query.searchText },
                    set: { viewModel.updateSearchText($0) }
                ),
                prompt: "Search Hacker News..."
            )
            .task {
                await viewModel.loadIfNeeded()
            }
        }
    }

    private var tabFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FeedTab.allCases) { tab in
                    let isSelected = viewModel.query.tab == tab
                    Button {
                        withAnimation(AppMotion.snappy) {
                            viewModel.selectTab(tab)
                        }
                    } label: {
                        Label(tab.title, systemImage: tab.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(isSelected ? .white : .primary)
                            .background(
                                isSelected ? AnyShapeStyle(AppTheme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.12)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var searchSortBar: some View {
        HStack {
            Text("Sort search by")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Picker("Sort search by", selection: Binding(
                get: { viewModel.query.sortMode },
                set: { viewModel.selectSortMode($0) }
            )) {
                ForEach(FeedSortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 210)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.06))
    }

    @ViewBuilder
    private var contentView: some View {
        if viewModel.articles.isEmpty {
            switch viewModel.paginationState {
            case .loadingInitial:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading stories...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failedInitial(let message):
                EmptyStateView(
                    systemImage: "wifi.exclamationmark",
                    title: "Couldn't Load Feed",
                    subtitle: message,
                    actionTitle: "Try Again",
                    action: { viewModel.retryInitial() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            default:
                EmptyStateView(
                    systemImage: "doc.text.magnifyingglass",
                    title: viewModel.query.trimmedSearchText.isEmpty ? "No Stories Available" : "No Matching Stories",
                    subtitle: viewModel.query.trimmedSearchText.isEmpty
                        ? "Pull to refresh or switch feeds."
                        : "Try a different keyword or switch feed tabs.",
                    actionTitle: "Refresh",
                    action: { viewModel.retryInitial() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List {
                ForEach(viewModel.articles) { article in
                    ArticleRowView(article: article)
                        .onAppear {
                            viewModel.loadNextPageIfNeeded(currentArticleID: article.id)
                        }
                }

                PaginationFooterView(
                    state: viewModel.paginationState,
                    hasArticles: !viewModel.articles.isEmpty,
                    onRetry: { viewModel.retryNextPage() }
                )
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .refreshable {
                await viewModel.refresh()
            }
        }
    }
}
