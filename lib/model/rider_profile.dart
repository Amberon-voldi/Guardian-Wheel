class RiderProfile {
  const RiderProfile({
    required this.id,
    required this.name,
    required this.phone,
    required this.bikeModel,
    required this.bloodGroup,
    required this.firstEmergencyName,
    required this.firstEmergencyContact,
    required this.secondEmergencyName,
    required this.secondEmergencyContact,
  });

  final String id;
  final String name;
  final String phone;
  final String bikeModel;
  final String bloodGroup;
  final String firstEmergencyName;
  final String firstEmergencyContact;
  final String secondEmergencyName;
  final String secondEmergencyContact;

  factory RiderProfile.empty(String id) {
    return RiderProfile(
      id: id,
      name: '',
      phone: '',
      bikeModel: '',
      bloodGroup: '',
      firstEmergencyName: '',
      firstEmergencyContact: '',
      secondEmergencyName: '',
      secondEmergencyContact: '',
    );
  }

  factory RiderProfile.fromMap(String id, Map<String, dynamic> map) {
    return RiderProfile(
      id: id,
      name: (map['name'] ?? '') as String,
      phone: (map['phone'] ?? '') as String,
      bikeModel: (map['bike_model'] ?? '') as String,
      bloodGroup: (map['blood_group'] ?? '') as String,
      firstEmergencyName: (map['1_emergency_name'] ?? '') as String,
      firstEmergencyContact: (map['1_emergency_contact'] ?? '') as String,
      secondEmergencyName: (map['2_emergency_name'] ?? '') as String,
      secondEmergencyContact: (map['2_emergency_contact'] ?? '') as String,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phone': phone,
      'bike_model': bikeModel,
      'blood_group': bloodGroup,
      '1_emergency_name': firstEmergencyName,
      '1_emergency_contact': firstEmergencyContact,
      '2_emergency_name': secondEmergencyName,
      '2_emergency_contact': secondEmergencyContact,
    };
  }

  RiderProfile copyWith({
    String? name,
    String? phone,
    String? bikeModel,
    String? bloodGroup,
    String? firstEmergencyName,
    String? firstEmergencyContact,
    String? secondEmergencyName,
    String? secondEmergencyContact,
  }) {
    return RiderProfile(
      id: id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      bikeModel: bikeModel ?? this.bikeModel,
      bloodGroup: bloodGroup ?? this.bloodGroup,
      firstEmergencyName: firstEmergencyName ?? this.firstEmergencyName,
      firstEmergencyContact: firstEmergencyContact ?? this.firstEmergencyContact,
      secondEmergencyName: secondEmergencyName ?? this.secondEmergencyName,
      secondEmergencyContact: secondEmergencyContact ?? this.secondEmergencyContact,
    );
  }
}
