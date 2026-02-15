import 'package:flutter/material.dart';

class RiderProfileScreen extends StatelessWidget {
  const RiderProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Rider Profile')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const CircleAvatar(radius: 48, backgroundImage: NetworkImage('https://lh3.googleusercontent.com/aida-public/AB6AXuCqbKXQv77n19YdL2XAq24NB-tjGfjOJaGXrjCxuNNgVmsth4jI3jzM6BjB_f5IizDBmlnZahoSiuJK5p58CYPuCmuSJmFhSYrF0vpxCww8NGX88vmec6gzRm7sDUKkldwNhTWgStzCW7EKWwKYM1jQd6zolfF7Sg64kas0eCai7adtPQv0w2EKUAeCTdh1xXAalacEfmGQS_bFTpK-N4xSVzKeahPzyzqFfzOZYVaC-6RB3mUrsGFE5kQT2DVFemODj8wV9pXlvkc')),
            const SizedBox(height: 12),
            Center(
              child: Text('Rajesh Kumar', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 8),
            Center(
              child: Wrap(
                spacing: 8,
                children: [
                  Chip(label: Text('⭐ 4.9', style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800))),
                  const Chip(label: Text('1,240 DELIVERIES')),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('#KA-05-9922', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                    SizedBox(height: 10),
                    _InfoRow(label: 'Vehicle Reg', value: 'KA 01 EQ 1234'),
                    _InfoRow(label: 'Blood Group', value: 'O+ (Positive)'),
                    _InfoRow(label: 'Emergency Zone', value: 'Bangalore South'),
                    _InfoRow(label: 'Valid Thru', value: '12/2025'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('SOS Contacts', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const _ContactCard(name: 'Priya (Wife)', phone: '+91 98*** **453', initials: 'P'),
            const _ContactCard(name: 'Fleet Manager', phone: '+91 99*** **112', initials: 'FM'),
            OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.add), label: const Text('Add Emergency Contact')),
            const SizedBox(height: 16),
            Text('Tactical Settings', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const _ToggleTile(
              title: 'Crash Detect Auto-SOS',
              subtitle: 'Automatically broadcast help signal if a crash is detected via accelerometer.',
              value: true,
            ),
            const _ToggleTile(
              title: 'Share Live Location',
              subtitle: 'Allow mesh peers to see your real-time position on the tactical map.',
              value: false,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.labelMedium)),
          Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.name, required this.phone, required this.initials});

  final String name;
  final String phone;
  final String initials;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Text(initials)),
        title: Text(name),
        subtitle: Text(phone),
        trailing: IconButton(icon: const Icon(Icons.call), onPressed: () {}),
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({required this.title, required this.subtitle, required this.value});

  final String title;
  final String subtitle;
  final bool value;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: SwitchListTile(
        value: value,
        onChanged: (_) {},
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
      ),
    );
  }
}