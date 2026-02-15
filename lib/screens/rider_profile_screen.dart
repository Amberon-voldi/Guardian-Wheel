import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../model/rider_profile.dart';
import '../service/user_profile_service.dart';
import '../theme/guardian_theme.dart';

class RiderProfileScreen extends StatefulWidget {
  const RiderProfileScreen({
    required this.userId,
    required this.userProfileService,
    super.key,
  });

  final String userId;
  final UserProfileService userProfileService;

  @override
  State<RiderProfileScreen> createState() => _RiderProfileScreenState();
}

class _RiderProfileScreenState extends State<RiderProfileScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _bikeModelController = TextEditingController();
  final _bloodGroupController = TextEditingController();
  final _e1NameController = TextEditingController();
  final _e1ContactController = TextEditingController();
  final _e2NameController = TextEditingController();
  final _e2ContactController = TextEditingController();

  RiderProfile? _profile;
  bool _loading = true;
  bool _saving = false;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _loading = true);
    try {
      final profile = await widget.userProfileService.fetchProfile(widget.userId);
      _bind(profile);
      if (mounted) {
        setState(() {
          _profile = profile;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load profile: $error')),
        );
      }
    }
  }

  void _bind(RiderProfile profile) {
    _nameController.text = profile.name;
    _phoneController.text = profile.phone;
    _bikeModelController.text = profile.bikeModel;
    _bloodGroupController.text = profile.bloodGroup;
    _e1NameController.text = profile.firstEmergencyName;
    _e1ContactController.text = profile.firstEmergencyContact;
    _e2NameController.text = profile.secondEmergencyName;
    _e2ContactController.text = profile.secondEmergencyContact;
  }

  Future<void> _save() async {
    if (_profile == null || _saving) return;
    setState(() => _saving = true);

    final updated = _profile!.copyWith(
      name: _nameController.text.trim(),
      phone: _phoneController.text.trim(),
      bikeModel: _bikeModelController.text.trim(),
      bloodGroup: _bloodGroupController.text.trim(),
      firstEmergencyName: _e1NameController.text.trim(),
      firstEmergencyContact: _e1ContactController.text.trim(),
      secondEmergencyName: _e2NameController.text.trim(),
      secondEmergencyContact: _e2ContactController.text.trim(),
    );

    try {
      final saved = await widget.userProfileService.saveProfile(updated);
      if (mounted) {
        setState(() {
          _profile = saved;
          _saving = false;
          _isEditing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully.')),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save profile: $error')),
        );
      }
    }
  }

  Future<void> _call(String phone) async {
    if (phone.trim().isEmpty) return;
    final uri = Uri.parse('tel:${phone.trim()}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _bikeModelController.dispose();
    _bloodGroupController.dispose();
    _e1NameController.dispose();
    _e1ContactController.dispose();
    _e2NameController.dispose();
    _e2ContactController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = _profile;

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // ── Header ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Profile', style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900, letterSpacing: -0.5,
                          )),
                          const SizedBox(height: 2),
                          Text(
                            'Your rider information',
                            style: theme.textTheme.bodySmall?.copyWith(color: GuardianTheme.textSecondary),
                          ),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () {
                                if (_isEditing) {
                                  if (profile != null) _bind(profile);
                                  setState(() => _isEditing = false);
                                } else {
                                  setState(() => _isEditing = true);
                                }
                              },
                        icon: Icon(_isEditing ? Icons.close : Icons.edit_outlined, size: 18),
                        label: Text(_isEditing ? 'Cancel' : 'Edit'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  CircleAvatar(
                    radius: 44,
                    backgroundColor: GuardianTheme.primaryOrange.withValues(alpha: 0.1),
                    child: Text(
                      (_nameController.text.trim().isNotEmpty
                              ? _nameController.text.trim()[0]
                              : 'R')
                          .toUpperCase(),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: GuardianTheme.primaryOrange,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      _valueOrFallback(_nameController.text, 'Rider'),
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Wrap(
                      spacing: 8,
                      children: [
                        Chip(label: Text('ID: ${widget.userId}')),
                        Chip(label: Text('Blood: ${_valueOrFallback(_bloodGroupController.text, 'N/A')}')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Profile Details', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          if (_isEditing) ...[
                            _field(_nameController, 'Full Name', icon: Icons.person_outline),
                            const SizedBox(height: 10),
                            _field(_phoneController, 'Phone', icon: Icons.phone_outlined, keyboardType: TextInputType.phone),
                            const SizedBox(height: 10),
                            _field(_bikeModelController, 'Bike Model', icon: Icons.two_wheeler_outlined),
                            const SizedBox(height: 10),
                            _field(_bloodGroupController, 'Blood Group', icon: Icons.bloodtype_outlined),
                          ] else ...[
                            _InfoRow(label: 'Phone', value: _valueOrFallback(_phoneController.text, 'Not set')),
                            _InfoRow(label: 'Bike Model', value: _valueOrFallback(_bikeModelController.text, 'Not set')),
                            _InfoRow(label: 'Blood Group', value: _valueOrFallback(_bloodGroupController.text, 'Not set')),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('SOS Contacts', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  if (_isEditing) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            _field(_e1NameController, 'Emergency Contact 1 Name', icon: Icons.contact_phone_outlined),
                            const SizedBox(height: 10),
                            _field(_e1ContactController, 'Emergency Contact 1 Phone', icon: Icons.phone_in_talk_outlined, keyboardType: TextInputType.phone),
                            const SizedBox(height: 10),
                            _field(_e2NameController, 'Emergency Contact 2 Name', icon: Icons.contact_phone_outlined),
                            const SizedBox(height: 10),
                            _field(_e2ContactController, 'Emergency Contact 2 Phone', icon: Icons.phone_in_talk_outlined, keyboardType: TextInputType.phone),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_saving ? 'Saving...' : 'Save Changes'),
                    ),
                  ] else ...[
                    _ContactCard(
                      name: _valueOrFallback(_e1NameController.text, 'Emergency Contact 1'),
                      phone: _valueOrFallback(_e1ContactController.text, 'Not set'),
                      initials: _initials(_e1NameController.text),
                      onCall: () => _call(_e1ContactController.text),
                    ),
                    _ContactCard(
                      name: _valueOrFallback(_e2NameController.text, 'Emergency Contact 2'),
                      phone: _valueOrFallback(_e2ContactController.text, 'Not set'),
                      initials: _initials(_e2NameController.text),
                      onCall: () => _call(_e2ContactController.text),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  String _valueOrFallback(String value, String fallback) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  String _initials(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'EC';
    final parts = trimmed.split(' ').where((e) => e.isNotEmpty).toList();
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'.toUpperCase();
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
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
  const _ContactCard({
    required this.name,
    required this.phone,
    required this.initials,
    required this.onCall,
  });

  final String name;
  final String phone;
  final String initials;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Text(initials)),
        title: Text(name),
        subtitle: Text(phone),
        trailing: IconButton(icon: const Icon(Icons.call), onPressed: onCall),
      ),
    );
  }
}
