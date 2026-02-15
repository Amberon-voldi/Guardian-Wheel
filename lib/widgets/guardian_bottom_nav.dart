import 'package:flutter/material.dart';

class GuardianBottomNav extends StatelessWidget {
  const GuardianBottomNav({
    required this.currentIndex,
    required this.onTap,
    super.key,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  static const _items = <(IconData, String)>[
    (Icons.shield_outlined, 'SOS'),
    (Icons.map_outlined, 'Map'),
    (Icons.notifications_outlined, 'Alerts'),
    (Icons.person_outline, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.2))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: List.generate(_items.length, (index) {
              final selected = currentIndex == index;
              final item = _items[index];
              return Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onTap(index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          item.$1,
                          color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.$2,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}