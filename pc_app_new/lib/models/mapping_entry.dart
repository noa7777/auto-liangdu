class MappingEntry {
  int lux;
  int brightness;

  MappingEntry({required this.lux, required this.brightness});

  Map<String, dynamic> toJson() => {'lux': lux, 'brightness': brightness};

  factory MappingEntry.fromJson(Map<String, dynamic> json) =>
      MappingEntry(lux: json['lux'] ?? 0, brightness: json['brightness'] ?? 50);
}
