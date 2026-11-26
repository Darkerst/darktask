/// Momentopname van de batterij in echte energie-eenheden (mWh/mW) in
/// plaats van hele procenten. Nodig voor korte verbruiksmetingen: 1% van
/// een 42 Wh-accu is ~420 mWh, dus in drie minuten zie je met alleen
/// procenten hooguit één of twee stappen, terwijl mWh en het gemelde
/// verbruik (mW) veel fijner zijn.
class BatteryEnergySample {
  /// Resterende energie in mWh.
  final double remainingMWh;

  /// Energie bij volledig geladen in mWh (huidige, niet de ontwerp-waarde),
  /// als bekend.
  final double? fullChargeMWh;

  /// Door de batterij gemeld verbruik in mW (altijd positief) terwijl hij
  /// ontlaadt; null als onbekend of niet aan het ontladen.
  final double? drawMW;

  /// true = ontlaadt, false = laadt of netstroom, null = onbekend.
  final bool? discharging;

  const BatteryEnergySample({
    required this.remainingMWh,
    this.fullChargeMWh,
    this.drawMW,
    this.discharging,
  });
}
