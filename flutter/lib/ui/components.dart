import 'package:anvil/anvil.dart';
import 'package:flutter/material.dart';

/// The Flutter faces of the app's Anvil components (1:1 with the Swift and
/// Android sets). The vendored anvil package is theme-only, so these are thin
/// Material 3 wrappers pinned to the Anvil semantic tokens.

/// AnvilBadge: medium-weight label on a tonal status capsule.
enum BadgeStatus { info, success, warning, critical, promo }

class DittoBadge extends StatelessWidget {
  const DittoBadge(this.text, {super.key, this.status = BadgeStatus.info});
  final String text;
  final BadgeStatus status;

  Color _fill(BuildContext context) {
    final colors = context.dittoColors;
    return switch (status) {
      BadgeStatus.info => colors.fillInfoSecondary,
      BadgeStatus.success => colors.fillSuccessSecondary,
      BadgeStatus.warning => colors.fillWarningSecondary,
      BadgeStatus.critical => colors.fillCriticalSecondary,
      BadgeStatus.promo => colors.fillPromoSecondary,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: _fill(context), shape: BoxShape.circle, borderRadius: BorderRadius.circular(999)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: context.dittoColors.foregroundNormal,
        ),
      ),
    );
  }
}

/// AnvilCard: surface fill, 12px corners, 1px normal border, 16px padding.
class DittoCard extends StatelessWidget {
  const DittoCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.borderNormal),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

/// AnvilButton primary = brand fill with on-brand content.
class DittoButton extends StatelessWidget {
  const DittoButton(this.title, {super.key, required this.onPressed, this.testKey});
  final String title;
  final VoidCallback onPressed;
  final Key? testKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return FilledButton(
      key: testKey,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: colors.fillBrandPrimary,
        foregroundColor: colors.foregroundOnBrandPrimary,
      ),
      child: Text(title),
    );
  }
}

/// The standard search field for the list screens: magnifier leading icon and
/// — the parity ask from the iOS `.searchable` control — a × clear affordance
/// whenever the field has text. The debounce lives in the screen state.
class ZavaSearchField extends StatelessWidget {
  const ZavaSearchField({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.onChanged,
  });
  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: placeholder,
        hintStyle: TextStyle(color: colors.foregroundSubtle),
        prefixIcon: Icon(Icons.search, color: colors.foregroundSubtle),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: Icon(Icons.close, color: colors.foregroundSubtle, semanticLabel: 'Clear search'),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: colors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.borderNormal),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.borderNormal),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.borderStrong),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      style: TextStyle(color: colors.foregroundNormal),
    );
  }
}

/// Ghost placeholders shown while a screen's first emission for the current
/// store is in flight (never render another store's data).
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({super.key, this.height = 18, this.width});
  final double height;
  final double? width;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
    _opacity = Tween(begin: 1.0, end: 0.45).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        height: widget.height,
        width: widget.width,
        decoration: BoxDecoration(
          color: context.dittoColors.surfaceSecondary,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}

class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key, this.count = 6});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          for (var i = 0; i < count; i++)
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  Expanded(child: SkeletonBox(height: 16)),
                  SizedBox(width: 12),
                  SkeletonBox(height: 16, width: 80),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Matches a dashboard KPI grid cell.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const DittoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(height: 12, width: 90),
          SizedBox(height: 10),
          FractionallySizedBox(widthFactor: 0.6, child: SkeletonBox(height: 28)),
        ],
      ),
    );
  }
}

/// Shared pagination bar (Edge Studio's PaginationControls pattern, Anvil
/// styling): total count, page-size menu, prev/next with "page X of Y".
/// The DQL behind it is `… ORDER BY … LIMIT <pageSize> OFFSET <offset>`.
class PaginationBar extends StatelessWidget {
  const PaginationBar({
    super.key,
    required this.totalCount,
    required this.page,
    required this.pageSize,
    required this.pageSizes,
    required this.onPage,
    required this.onPageSize,
  });
  final int totalCount;
  final int page;
  final int pageSize;
  final List<int> pageSizes;
  final ValueChanged<int> onPage;
  final ValueChanged<int> onPageSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final pageCount = PagingHelper.pageCount(totalCount, pageSize);
    final mono = TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 12, color: colors.foregroundNormal);
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text('${_formatInt(totalCount)} total', style: mono.copyWith(color: colors.foregroundSubtle)),
          const Spacer(),
          MenuAnchor(
            menuChildren: [
              for (final size in pageSizes)
                MenuItemButton(
                  child: Text('$size per page'),
                  onPressed: () {
                    onPage(1);
                    onPageSize(size);
                  },
                ),
            ],
            builder: (context, controller, child) => TextButton(
              onPressed: () => controller.isOpen ? controller.close() : controller.open(),
              child: Text('Show $pageSize', style: TextStyle(color: colors.foregroundSubtle)),
            ),
          ),
          IconButton(
            key: const Key('PaginationPrevButton'),
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
            onPressed: page > 1 ? () => onPage(page - 1) : null,
            color: page > 1 ? colors.foregroundNormal : colors.foregroundDisabled,
          ),
          Semantics(
            identifier: 'PaginationPageIndicator',
            child: Text('$page of $pageCount', style: mono),
          ),
          IconButton(
            key: const Key('PaginationNextButton'),
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
            onPressed: page < pageCount ? () => onPage(page + 1) : null,
            color: page < pageCount ? colors.foregroundNormal : colors.foregroundDisabled,
          ),
        ],
      ),
    );
  }
}

/// Thousands-grouped integer (Swift's `Int.formatted()`).
String formatInt(int value) => _formatInt(value);
String _formatInt(int value) {
  final s = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final remaining = s.length - i;
    buffer.write(s[i]);
    if (remaining > 1 && remaining % 3 == 1) buffer.write(',');
  }
  return buffer.toString();
}

/// Page-count math, delegated to the shared model Paging (imported here to
/// keep this file's UI imports lean).
class PagingHelper {
  static int pageCount(int total, int pageSize) => _pageCount(total, pageSize);
  static int _pageCount(int total, int pageSize) {
    final count = (total / pageSize).ceil();
    return count < 1 ? 1 : count;
  }
}

/// Every data surface shows the ACTUAL DQL behind it (not a template) in an
/// info sheet — the app's core teaching move. Screen-level sheets live in the
/// app bar (the Android app's app-bar info action pattern); card-scoped ones
/// sit in card headers.
class QueryInfoButton extends StatelessWidget {
  const QueryInfoButton({super.key, required this.query, required this.explanation, this.tooltip = 'About this query'});
  final String query;
  final String explanation;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(Icons.info_outline, color: context.dittoColors.foregroundSubtle),
      onPressed: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (context) => QueryInfoSheet(query: query, explanation: explanation),
      ),
    );
  }
}

class QueryInfoSheet extends StatelessWidget {
  const QueryInfoSheet({super.key, required this.query, required this.explanation});
  final String query;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Container(
      color: colors.surface,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Text('About this data', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                  const Spacer(),
                  IconButton(
                    key: const Key('queryInfo.close'),
                    icon: Icon(Icons.close, color: colors.foregroundSubtle),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.borderNormal),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('The DQL behind this', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                    const SizedBox(height: 8),
                    CodeBlock(query),
                    const SizedBox(height: 16),
                    Text('What it does', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                    const SizedBox(height: 8),
                    Text(explanation, style: TextStyle(fontSize: 14, color: colors.foregroundSubtle)),
                    const SizedBox(height: 16),
                    Text(
                      'Tip: every query in the app runs against data synced by Ditto — offline-first, live-updating.',
                      style: TextStyle(fontSize: 12, color: colors.foregroundSubtle),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Monospaced, selectable code block (the DQL viewer — IBM Plex Mono on the
/// Anvil code colors, rounded codeBackground panel).
class CodeBlock extends StatelessWidget {
  const CodeBlock(this.text, {super.key, this.fontSize = 12});
  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: colors.codeBackground, borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(10),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'packages/anvil/IBMPlexMono',
          fontSize: fontSize,
          color: colors.codeForeground,
        ),
      ),
    );
  }
}

/// Card-section header: title + optional info button, the recurring pattern.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.query, this.explanation, this.trailing});
  final String title;
  final String? query;
  final String? explanation;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.dittoColors.foregroundNormal),
        ),
        const Spacer(),
        ?trailing,
        if (query != null && explanation != null) QueryInfoButton(query: query!, explanation: explanation!),
      ],
    );
  }
}
