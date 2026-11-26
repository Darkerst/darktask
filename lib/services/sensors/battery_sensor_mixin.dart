import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../core/models/battery_energy_sample.dart';
import '../../core/models/battery_sample.dart';

const _logSource = 'LinuxSensorService';

/// Battery presence/state — a small, separate domain from the rest of
/// the sensors since most machines DarkTask runs on (desktops) simply
/// don't have one; every read here is written to degrade to
/// [BatterySample.absent] rather than error, so callers never need a
/// special case for "no battery installed".
///
/// Split out of the former single `LinuxSensorService` god-file — see
/// `linux_sensor_service.dart` for how the domain mixins are composed.
mixin BatterySensorMixin {
  /// Resterende energie (mWh) en verbruik (mW) uit sysfs. Batterijen
  /// leveren óf energie-bestanden (energy_now in µWh, power_now in µW) óf
  /// lading-bestanden (charge_now in µAh, current_now in µA, plus
  /// voltage_now in µV); in het tweede geval wordt met de spanning naar
  /// mWh/mW omgerekend. Null bij elke twijfel, dan valt de aanroeper terug
  /// op procenten.
  Future<BatteryEnergySample?> readBatteryEnergy() async {
    try {
      final psDir = Directory('/sys/class/power_supply');
      if (!await psDir.exists()) return null;

      Future<double?> readNum(String dir, String file) async {
        try {
          return double.tryParse((await File('$dir/$file').readAsString()).trim());
        } catch (_) {
          return null;
        }
      }

      await for (final entry in psDir.list()) {
        final name = entry.path.split('/').last;
        if (!name.startsWith('BAT')) continue;
        final dir = entry.path;

        double remaining; // mWh
        double? full; // mWh
        double? draw; // mW

        final energyNow = await readNum(dir, 'energy_now');
        if (energyNow != null) {
          remaining = energyNow / 1000; // µWh -> mWh
          final energyFull = await readNum(dir, 'energy_full');
          if (energyFull != null) full = energyFull / 1000;
          final powerNow = await readNum(dir, 'power_now');
          if (powerNow != null) draw = powerNow / 1000; // µW -> mW
        } else {
          final chargeNow = await readNum(dir, 'charge_now');
          final voltage = await readNum(dir, 'voltage_now');
          if (chargeNow == null || voltage == null) continue;
          remaining = chargeNow * voltage / 1e9; // µAh * µV -> mWh
          final chargeFull = await readNum(dir, 'charge_full');
          if (chargeFull != null) full = chargeFull * voltage / 1e9;
          final currentNow = await readNum(dir, 'current_now');
          if (currentNow != null) draw = currentNow * voltage / 1e9; // µA * µV -> mW
        }

        String? status;
        try {
          status = (await File('$dir/status').readAsString()).trim();
        } catch (_) {}
        final discharging = status == null ? null : status.toLowerCase() == 'discharging';

        return BatteryEnergySample(
          remainingMWh: remaining,
          fullChargeMWh: full,
          drawMW: (discharging == true && draw != null && draw > 0) ? draw : null,
          discharging: discharging,
        );
      }
      return null;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read battery energy: $e');
      return null;
    }
  }

  Future<BatterySample> readBattery() async {
    try {
      final psDir = Directory('/sys/class/power_supply');
      if (!await psDir.exists()) return BatterySample.absent();

      await for (final entry in psDir.list()) {
        final name = entry.path.split('/').last;
        // BAT0, BAT1, ... — the standard kernel naming; anything else
        // under power_supply (AC, ADP1, ...) is the charger, not the
        // battery itself.
        if (!name.startsWith('BAT')) continue;

        final capacityFile = File('${entry.path}/capacity');
        if (!await capacityFile.exists()) continue;
        final capacity = int.tryParse((await capacityFile.readAsString()).trim());

        String? status;
        try {
          status = (await File('${entry.path}/status').readAsString()).trim();
        } catch (_) {
          // Some drivers don't expose a status file — capacity alone is
          // still useful, so don't fail the whole read over this.
        }

        // Health is computed from *design* vs *full-charge* capacity —
        // distinct from the "capacity" file above, which is the
        // current *charge level* (how full it is right now, out of
        // whatever it can currently hold). The kernel exposes this in
        // one of two unit families depending on the battery's fuel
        // gauge chip: energy_* in µWh, or charge_* in µAh — read
        // whichever pair exists, never mixed across the two, since a
        // ratio needs both values in the same unit to mean anything.
        double? designCapacity;
        double? fullChargeCapacity;
        try {
          final energyFullDesign = File('${entry.path}/energy_full_design');
          final energyFull = File('${entry.path}/energy_full');
          if (await energyFullDesign.exists() && await energyFull.exists()) {
            // µWh -> mWh.
            designCapacity = double.tryParse((await energyFullDesign.readAsString()).trim())! / 1000;
            fullChargeCapacity = double.tryParse((await energyFull.readAsString()).trim())! / 1000;
          } else {
            final chargeFullDesign = File('${entry.path}/charge_full_design');
            final chargeFull = File('${entry.path}/charge_full');
            if (await chargeFullDesign.exists() && await chargeFull.exists()) {
              // µAh is charge, not energy (mWh) — without a voltage
              // reading this can't be converted to true mWh, but
              // relative *health* only needs a consistent unit on both
              // sides of the ratio, so µAh directly (unconverted) is
              // used for both values here rather than presenting a
              // falsely-precise mWh figure this driver doesn't
              // actually provide.
              designCapacity = double.tryParse((await chargeFullDesign.readAsString()).trim());
              fullChargeCapacity = double.tryParse((await chargeFull.readAsString()).trim());
            }
          }
        } catch (e) {
          AppLogger.instance.debug(_logSource, 'Failed to read battery health capacities: $e');
        }

        int? cycleCount;
        try {
          final cycleCountFile = File('${entry.path}/cycle_count');
          if (await cycleCountFile.exists()) {
            // Some drivers expose the file but leave it at 0 when they
            // genuinely can't report a real count (rather than omitting
            // the file entirely) — treated the same as "not available"
            // rather than shown as a battery that has never been used
            // through a single cycle, which would be misleading for
            // anything but a brand-new machine.
            final raw = int.tryParse((await cycleCountFile.readAsString()).trim());
            if (raw != null && raw > 0) cycleCount = raw;
          }
        } catch (e) {
          AppLogger.instance.debug(_logSource, 'Failed to read battery cycle count: $e');
        }

        return BatterySample(
          present: true,
          capacityPercent: capacity,
          status: status,
          designCapacityMWh: designCapacity,
          fullChargeCapacityMWh: fullChargeCapacity,
          cycleCount: cycleCount,
        );
      }
      return BatterySample.absent(); // no BAT* entry found — desktop/server
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read battery state: $e');
      return BatterySample.absent();
    }
  }
}
