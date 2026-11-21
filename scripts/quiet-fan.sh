#!/bin/sh
# PS5 CachyOS: quieter fan curve + "SoC Temp" reading in the KDE panel.
#
# Install:  curl -fsSL https://raw.githubusercontent.com/MastaG/PS5-CachyOS/main/scripts/quiet-fan.sh | sh
# Remove:   curl -fsSL https://raw.githubusercontent.com/MastaG/PS5-CachyOS/main/scripts/quiet-fan.sh | sh -s -- --remove
#
# Run it as your normal user (NOT with sudo). It asks for your password itself
# for the fan part; the panel widget has to be added as you.
#
# Fan curve (temperature C -> fan speed 0-255):
#   kernel default: 50/60/65/70/75/80/85/87 -> 26/77/102/128/166/204/242/255
#   this script:    55/60/65/70/75/80/85/88 -> 5/16/31/48/67/120/190/255
# Still safe: full speed at 88 C, the driver forces full speed at 90 C anyway,
# and the GPU slows itself down at 85 C.
set -e

if [ "$(id -u)" = 0 ]; then
	echo "Run this as your normal user, without sudo (it asks for the password itself)." >&2
	exit 1
fi

SCRIPT=/usr/local/sbin/ps5-fan-curve
SERVICE=/etc/systemd/system/ps5-fan-curve.service

# --- KDE panel widget (Plasma scripting over D-Bus) ---
QDBUS=$(command -v qdbus6 || command -v qdbus || true)
plasma() {
	if [ -z "$QDBUS" ] || ! "$QDBUS" org.kde.plasmashell >/dev/null 2>&1; then
		echo "KDE desktop not running here, skipping the panel widget (run this again from desktop mode)."
		return 0
	fi
	"$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$1"
}

FIND_JS='
function isTemp(w) {
	if (w.type != "org.kde.plasma.systemmonitor") return false;
	w.currentConfigGroup = ["Appearance"];
	return w.readConfig("title", "") == "SoC Temp";
}'

if [ "$1" = "--remove" ]; then
	echo "Removing the quiet fan curve (password needed)..."
	sudo systemctl disable --now ps5-fan-curve.service 2>/dev/null || true
	sudo rm -f "$SERVICE" "$SCRIPT"
	sudo systemctl daemon-reload
	plasma "$FIND_JS
	panels().forEach(function (p) { p.widgets().forEach(function (w) { if (isTemp(w)) w.remove(); }); });" >/dev/null
	echo "Done. Reboot to go back to the kernel's default fan curve."
	exit 0
fi

# --- Fan curve ---
if ! grep -qx ps5_fan /sys/class/hwmon/hwmon*/name 2>/dev/null; then
	echo "No ps5_fan driver found: this kernel has no fan curve support. Nothing changed." >&2
	exit 1
fi

echo "Installing the fan curve (password needed)..."
sudo tee "$SCRIPT" >/dev/null <<'EOF'
#!/bin/sh
# Smooth fan curve for the ps5-fan hwmon driver (ps5-linux-patches #60+): rises gradually, no silent-to-loud jumps;
# keeps the SoC around 73 C in games with boost on.
# Kernel default: 50/60/65/70/75/80/85/87 C -> pwm 26/77/102/128/166/204/242/255.
# The last point must stay 255; the driver forces full speed at 90 C regardless.
TEMPS="50 55 60 65 70 75 80 88"
PWMS="40 50 60 72 85 100 125 255"
for h in /sys/class/hwmon/hwmon*; do
	[ "$(cat $h/name 2>/dev/null)" = ps5_fan ] && H=$h
done
[ -n "$H" ] || { echo "no ps5_fan hwmon (old kernel?), nothing to do"; exit 0; }
# Points must stay ordered after every single write, so retry a few passes.
# Write both ways each pass: a raised curve needs high points first, a lowered one low points first.
for pass in 1 2 3 4 5 6 7 8; do
	i=8; for t in $(echo $TEMPS | tr ' ' '\n' | tac); do
		echo $((t * 1000)) > $H/pwm1_auto_point${i}_temp 2>/dev/null; i=$((i - 1)); done
	i=1; for t in $TEMPS; do
		echo $((t * 1000)) > $H/pwm1_auto_point${i}_temp 2>/dev/null; i=$((i + 1)); done
	i=8; for p in $(echo $PWMS | tr ' ' '\n' | tac); do
		echo $p > $H/pwm1_auto_point${i}_pwm 2>/dev/null; i=$((i - 1)); done
	i=1; for p in $PWMS; do
		echo $p > $H/pwm1_auto_point${i}_pwm 2>/dev/null; i=$((i + 1)); done
done
i=1; while [ $i -le 8 ]; do
	printf '%sC=%s ' $(( $(cat $H/pwm1_auto_point${i}_temp) / 1000 )) $(cat $H/pwm1_auto_point${i}_pwm); i=$((i + 1))
done; echo
EOF
sudo chmod 755 "$SCRIPT"

sudo tee "$SERVICE" >/dev/null <<'EOF'
[Unit]
Description=Apply quieter PS5 fan curve (ps5-fan hwmon)
After=ps5fan.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-fan-curve

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable ps5-fan-curve.service >/dev/null 2>&1
echo "Fan curve now:"
sudo "$SCRIPT"

# --- Temperature in the panel ---
echo "Adding 'SoC Temp' to the panel..."
plasma "$FIND_JS
var p = panels()[0], have = false;
panels().forEach(function (q) { q.widgets().forEach(function (w) { if (isTemp(w)) have = true; }); });
if (!p) { print(\"no panel found\"); }
else if (have) { print(\"already in the panel\"); }
else {
	var w = p.addWidget(\"org.kde.plasma.systemmonitor\");
	w.currentConfigGroup = [\"Appearance\"];
	w.writeConfig(\"chartFace\", \"org.kde.ksysguard.textonly\");
	w.writeConfig(\"title\", \"SoC Temp\");
	w.currentConfigGroup = [\"Sensors\"];
	w.writeConfig(\"highPrioritySensorIds\", '[\"cpu/all/maximumTemperature\"]');
	w.currentConfigGroup = [\"SensorColors\"];
	w.writeConfig(\"cpu/all/maximumTemperature\", \"48,128,170\");
	w.reloadConfig();
	print(\"added (drag it where you like in Edit Mode)\");
}"
echo
echo "Done. The fan curve stays on after reboots. To undo: run this again with --remove."
