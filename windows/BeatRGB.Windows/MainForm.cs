using BeatRGB.Core;
using BeatRGB.Core.Effects;
using BeatRGB.Core.Engine;
using BeatRGB.Core.OpenRGB;

namespace BeatRGB.Windows;

/// <summary>
/// The BeatRGB window: keyboard preview, sync button, profiles, and tabs for lighting, keyboard,
/// background and diagnostics settings. Closing the window keeps BeatRGB running in the notification area.
/// </summary>
public sealed class MainForm : Form
{
    private readonly LightingEngine _engine = new();
    private readonly SystemAudioCapture _audio = new();
    private readonly ScreenSampler _screen = new();
    private readonly JsonStore<ProfileLibrary> _profileStore = new(Path.Combine(JsonStore<ProfileLibrary>.DefaultDirectory, "profiles.json"));
    private readonly JsonStore<AppPreferences> _prefsStore = new(Path.Combine(JsonStore<AppPreferences>.DefaultDirectory, "settings.json"));
    private readonly ProfileLibrary _library;
    private readonly AppPreferences _prefs;
    private readonly bool _startInBackground;
    private readonly System.Windows.Forms.Timer _saveTimer = new() { Interval = 500 };
    private bool _syncing, _quitting, _loading;
    private string _audioState = "Stopped";
    private EngineSnapshot _snapshot = new();
    private string _lastLogLine = "";

    // Controls
    private readonly NotifyIcon _tray = new();
    private readonly KeyboardPreview _preview = new() { Dock = DockStyle.Fill };
    private readonly Button _syncButton = new() { Text = "Start sync", Width = 120, Height = 34 };
    private readonly Label _status = new() { AutoSize = true, Padding = new Padding(8, 9, 0, 0) };
    private readonly ComboBox _profileBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
    private readonly ListBox _effectList = new() { Width = 210, Dock = DockStyle.Left, IntegralHeight = false };
    private readonly FlowLayoutPanel _effectOptions = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(10, 4, 4, 4) };
    private readonly ComboBox _deviceBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 340 };
    private readonly TextBox _logBox = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font("Consolas", 9) };
    private readonly Label _diagnostics = new() { AutoSize = true, Dock = DockStyle.Top, Padding = new Padding(4) };
    private readonly Label _testResult = new() { AutoSize = true };

    public MainForm(bool startInBackground)
    {
        _startInBackground = startInBackground;
        _library = _profileStore.Load() is { Profiles.Count: > 0 } lib ? lib : ProfileLibrary.BuiltIn();
        _prefs = _prefsStore.Load() ?? new AppPreferences();

        Text = "BeatRGB";
        Icon = LoadIcon();
        MinimumSize = new Size(900, 640);
        Size = new Size(1040, 760);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9.5f);

        BuildTray();
        BuildLayout();
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); _profileStore.Save(_library); };

        _engine.SnapshotChanged += s => { if (IsHandleCreated) BeginInvoke(() => OnSnapshot(s)); };
        _audio.StateChanged += s => { if (IsHandleCreated) BeginInvoke(() => _audioState = s); };
        _engine.Configure(_prefs.EngineConfig);
        PushSettings();
        _engine.SetScreenSource(() => _screen.Latest);
    }

    protected override void SetVisibleCore(bool value)
    {
        // Open straight to the notification area when asked to run in the background.
        if (!IsHandleCreated && (_startInBackground || _prefs.OpenInBackground))
        {
            CreateHandle();
            value = false;
        }
        base.SetVisibleCore(value);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (_prefs.StartSyncOnLaunch) BeginInvoke(StartSync);
        BeginInvoke(RefreshDevices);
    }

    private static Icon LoadIcon()
    {
        using var s = typeof(MainForm).Assembly.GetManifestResourceStream("BeatRGB.ico");
        return s != null ? new Icon(s) : SystemIcons.Application;
    }

    private LightingSettings Settings => _library.Active!.Settings;

    // MARK: Layout

    private void BuildTray()
    {
        _tray.Icon = LoadIcon();
        _tray.Text = "BeatRGB";
        _tray.Visible = true;
        var menu = new ContextMenuStrip();
        var toggle = menu.Items.Add("Start sync", null, (_, _) => ToggleSync());
        menu.Items.Add("Show BeatRGB", null, (_, _) => ShowWindow());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit BeatRGB", null, (_, _) => Quit());
        menu.Opening += (_, _) => toggle.Text = _syncing ? "Stop sync" : "Start sync";
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => ShowWindow();
    }

    private void BuildLayout()
    {
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 48, Padding = new Padding(8, 7, 8, 0) };
        _syncButton.Click += (_, _) => ToggleSync();
        top.Controls.Add(_syncButton);
        top.Controls.Add(new Label { Text = "Profile", AutoSize = true, Padding = new Padding(16, 9, 0, 0) });
        top.Controls.Add(_profileBox);
        var newProfile = new Button { Text = "Duplicate", AutoSize = true, Height = 30 };
        var renameProfile = new Button { Text = "Rename", AutoSize = true, Height = 30 };
        var deleteProfile = new Button { Text = "Delete", AutoSize = true, Height = 30 };
        newProfile.Click += (_, _) => DuplicateProfile();
        renameProfile.Click += (_, _) => RenameProfile();
        deleteProfile.Click += (_, _) => DeleteProfile();
        top.Controls.AddRange([newProfile, renameProfile, deleteProfile, _status]);
        _profileBox.SelectedIndexChanged += (_, _) =>
        {
            if (_loading || _profileBox.SelectedIndex < 0) return;
            _library.ActiveId = _library.Profiles[_profileBox.SelectedIndex].Id;
            SettingsChanged();
            LoadEffectList();
        };

        var previewHost = new Panel { Dock = DockStyle.Top, Height = 230, Padding = new Padding(8) };
        previewHost.Controls.Add(_preview);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(LightingTab());
        tabs.TabPages.Add(KeyboardTab());
        tabs.TabPages.Add(BackgroundTab());
        tabs.TabPages.Add(DiagnosticsTab());

        Controls.Add(tabs);
        Controls.Add(previewHost);
        Controls.Add(top);
        LoadProfiles();
    }

    private TabPage LightingTab()
    {
        var page = new TabPage("Lighting");
        foreach (var kind in Enum.GetValues<EffectKind>()) _effectList.Items.Add(kind.Title());
        _effectList.SelectedIndexChanged += (_, _) =>
        {
            if (_loading || _effectList.SelectedIndex < 0) return;
            Settings.Effect = (EffectKind)_effectList.SelectedIndex;
            SettingsChanged();
            BuildEffectOptions();
            UpdateScreenSampler();
        };
        page.Controls.Add(_effectOptions);
        page.Controls.Add(_effectList);
        return page;
    }

    /// <summary>Rebuilds the option list for the selected effect, like the Mac app's Studio view.</summary>
    private void BuildEffectOptions()
    {
        _effectOptions.SuspendLayout();
        _effectOptions.Controls.Clear();
        var s = Settings;
        var e = s.Effect;
        Header("Colour");
        if (e == EffectKind.Spectrum)
            Choice("Style", Enum.GetValues<SpectrumStyle>().Select(x => x.Title()).ToArray(), (int)s.SpectrumStyle, i => { s.SpectrumStyle = (SpectrumStyle)i; BuildEffectOptions(); });
        bool gradient = e == EffectKind.Spectrum && s.SpectrumStyle == SpectrumStyle.Gradient;
        if (e.UsesPrimaryColor() && !(e == EffectKind.Spectrum && s.SpectrumStyle == SpectrumStyle.Multicolor))
            ColourButton(gradient ? "Bottom colour" : e == EffectKind.MirrorSpectrum ? "Centre colour" : "Colour", () => s.PrimaryColor, c => s.PrimaryColor = c);
        if (gradient || e == EffectKind.MirrorSpectrum)
            ColourButton(gradient ? "Top colour" : "Edge colour", () => s.SecondaryColor, c => s.SecondaryColor = c);
        Slider("Brightness", 0, 1, () => s.Brightness, v => s.Brightness = v, v => $"{v * 100:0}%");
        Slider("Speed", 0.1, 3, () => s.Speed, v => s.Speed = v, v => $"{v:0.0}×");

        if (e == EffectKind.BassPulse)
        {
            Header("Bass pulse");
            Slider("Attack", 5, 200, () => s.PulseAttackMs, v => s.PulseAttackMs = v, v => $"{v:0} ms");
            Slider("Decay", 50, 1500, () => s.PulseDecayMs, v => s.PulseDecayMs = v, v => $"{v:0} ms");
            Slider("Baseline brightness", 0, 0.6, () => s.Baseline, v => s.Baseline = v, v => $"{v * 100:0}%");
        }
        if (e == EffectKind.ScreenMirror)
        {
            Header("Screen Mirror");
            Note("Keys take the colour of the matching area of your display: the top row follows the top of the screen, the left keys the left edge.");
            Slider("Screen brightness", 1, 4, () => s.ScreenGain, v => s.ScreenGain = v, v => $"{v:0.0}×");
            Slider("Colour boost", 0, 1, () => s.ScreenSaturation, v => s.ScreenSaturation = v, v => $"{v * 100:0}%");
            Choice("Display", Screen.AllScreens.Select((x, i) => $"Display {i + 1} ({x.Bounds.Width}×{x.Bounds.Height}){(x.Primary ? " — main" : "")}").ToArray(),
                   Math.Min(s.ScreenDisplayIndex, Screen.AllScreens.Length - 1), i => { s.ScreenDisplayIndex = i; UpdateScreenSampler(restart: true); });
        }
        if (e.IsAudioReactive())
        {
            Header("Response");
            Slider("Sensitivity", 0.2, 2, () => s.Sensitivity, v => s.Sensitivity = v, v => $"{v:0.0}×");
            Slider("Smoothing", 0, 1, () => s.Smoothing, v => s.Smoothing = v, v => $"{v * 100:0}%");
            Slider("Bass responsiveness", 0, 2, () => s.BassResponse, v => s.BassResponse = v, v => $"{v:0.0}×");
            Check("Adaptive gain (auto-level)", () => s.AdaptiveGain, v => s.AdaptiveGain = v);
            Check("Noise gate", () => s.NoiseGateEnabled, v => s.NoiseGateEnabled = v);
            Slider("Gate threshold", -90, -30, () => s.NoiseGateDB, v => s.NoiseGateDB = v, v => $"{v:0} dBFS");

            Header("When music stops");
            Choice("Idle effect", Enum.GetValues<IdleKind>().Select(x => x.Title()).ToArray(), (int)s.Idle, i => s.Idle = (IdleKind)i);
            ColourButton("Idle colour", () => s.IdleColor, c => s.IdleColor = c);
            Slider("Go idle after", 0.5, 10, () => s.IdleDelay, v => s.IdleDelay = v, v => $"{v:0.0} s");
        }
        Slider("Target update rate", 10, 60, () => s.TargetFPS, v => s.TargetFPS = v, v => $"{v:0} fps");
        _effectOptions.ResumeLayout();
    }

    private TabPage KeyboardTab()
    {
        var page = new TabPage("Keyboard");
        var p = Column(page);
        p.Controls.Add(Bold("Works with any RGB keyboard OpenRGB supports"));
        p.Controls.Add(Wrap("BeatRGB drives your keyboard through OpenRGB's SDK server, so it works with Corsair, Razer, Logitech, SteelSeries, ASUS, HyperX, MSI, Redragon, Wooting and many more (see openrgb.org/devices). Effects are laid out from the key map OpenRGB reports for your keyboard.\n\n1. Install OpenRGB from openrgb.org and open it once so it detects your devices.\n2. In OpenRGB, open the SDK Server tab and click Start Server (port 6742). To start it automatically, enable it under Settings or launch OpenRGB with --server --startminimized.\n3. Quit the keyboard maker's own lighting software (iCUE, Synapse, G HUB, SteelSeries GG, Armoury Crate) or turn off its lighting control — only one program can drive the LEDs."));

        var conn = Row(p);
        conn.Controls.Add(new Label { Text = "OpenRGB host", AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
        var host = new TextBox { Text = _prefs.Host, Width = 140 };
        var port = new NumericUpDown { Minimum = 1, Maximum = 65535, Value = _prefs.Port, Width = 80 };
        conn.Controls.AddRange([host, new Label { Text = "port", AutoSize = true, Padding = new Padding(0, 6, 0, 0) }, port]);
        host.Leave += (_, _) => { _prefs.Host = host.Text.Trim(); PrefsChanged(); };
        port.ValueChanged += (_, _) => { _prefs.Port = (int)port.Value; PrefsChanged(); };

        var devRow = Row(p);
        devRow.Controls.Add(new Label { Text = "Keyboard", AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
        devRow.Controls.Add(_deviceBox);
        var refresh = new Button { Text = "Refresh", AutoSize = true };
        refresh.Click += (_, _) => RefreshDevices();
        devRow.Controls.Add(refresh);
        _deviceBox.SelectedIndexChanged += (_, _) =>
        {
            if (_loading) return;
            _prefs.DeviceName = _deviceBox.SelectedIndex <= 0 ? null : (string)_deviceBox.SelectedItem!;
            PrefsChanged();
        };

        var lockBox = new CheckBox { Text = "Only control this exact keyboard (match serial number)", AutoSize = true, Checked = _prefs.LockedSerial != null };
        lockBox.CheckedChanged += (_, _) =>
        {
            _prefs.LockedSerial = lockBox.Checked ? _snapshot.Device?.Serial : null;
            if (lockBox.Checked && _prefs.LockedSerial == null) { lockBox.Checked = false; MessageBox.Show("Start sync first so BeatRGB knows which keyboard to lock to.", "BeatRGB"); }
            PrefsChanged();
        };
        p.Controls.Add(lockBox);

        var stopRow = Row(p);
        stopRow.Controls.Add(new Label { Text = "When sync stops", AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
        var stop = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
        foreach (var b in Enum.GetValues<StopBehavior>()) stop.Items.Add(b.Title());
        stop.SelectedIndex = (int)_prefs.StopBehavior;
        stop.SelectedIndexChanged += (_, _) => { _prefs.StopBehavior = (StopBehavior)stop.SelectedIndex; PrefsChanged(); };
        stopRow.Controls.Add(stop);
        var reconnect = new CheckBox { Text = "Reconnect automatically", AutoSize = true, Checked = _prefs.AutoReconnect };
        reconnect.CheckedChanged += (_, _) => { _prefs.AutoReconnect = reconnect.Checked; PrefsChanged(); };
        p.Controls.Add(reconnect);

        p.Controls.Add(Bold("Hardware test"));
        p.Controls.Add(Wrap("Paints every key one colour through OpenRGB and reads the device back. Look at the keyboard to confirm the physical LEDs changed. Stop sync first."));
        var testRow = Row(p);
        var test = new Button { Text = "Send red to keyboard", AutoSize = true };
        test.Click += async (_, _) =>
        {
            if (_syncing) { _testResult.Text = "Stop sync first."; return; }
            _testResult.Text = "Sending…";
            _testResult.Text = await _engine.SendTestColorAsync(new RGB8(255, 0, 0));
        };
        testRow.Controls.AddRange([test, _testResult]);
        return page;
    }

    private TabPage BackgroundTab()
    {
        var page = new TabPage("Background");
        var p = Column(page);
        p.Controls.Add(Bold("Run in the background"));
        var openBg = new CheckBox { Text = "Open in the background (notification-area icon only, no window)", AutoSize = true, Checked = _prefs.OpenInBackground };
        var autoSync = new CheckBox { Text = "Start sync when BeatRGB opens", AutoSize = true, Checked = _prefs.StartSyncOnLaunch };
        var login = new CheckBox { Text = "Launch when I sign in to Windows", AutoSize = true, Checked = LaunchAtLogin.Enabled };
        openBg.CheckedChanged += (_, _) => { _prefs.OpenInBackground = openBg.Checked; PrefsChanged(); };
        autoSync.CheckedChanged += (_, _) => { _prefs.StartSyncOnLaunch = autoSync.Checked; PrefsChanged(); };
        login.CheckedChanged += (_, _) =>
        {
            try { LaunchAtLogin.Enabled = login.Checked; }
            catch (Exception ex) { MessageBox.Show($"Could not change the startup setting: {ex.Message}", "BeatRGB"); }
        };
        var full = new Button { Text = "Set up full background mode", AutoSize = true };
        full.Click += (_, _) => { openBg.Checked = true; autoSync.Checked = true; login.Checked = true; };
        p.Controls.AddRange([openBg, autoSync, login, full]);
        p.Controls.Add(Wrap("Closing the window keeps BeatRGB running and lighting the keyboard from its notification-area icon (near the clock); right-click the icon and choose Quit to exit. Full background mode turns on all three options, so lighting starts by itself when you sign in."));

        p.Controls.Add(Bold("Audio source"));
        p.Controls.Add(Wrap("BeatRGB hears everything Windows plays through the default output device (WASAPI loopback): Spotify, browsers, games and so on, without changing playback. It never uses a microphone. If you switch output devices, BeatRGB follows the new default."));
        return page;
    }

    private TabPage DiagnosticsTab()
    {
        var page = new TabPage("Diagnostics");
        var scan = new Button { Text = "Scan OpenRGB devices", AutoSize = true, Dock = DockStyle.Top };
        scan.Click += async (_, _) =>
        {
            try
            {
                var devices = await _engine.ScanAsync();
                _logBox.Text = devices.Count == 0 ? "OpenRGB reports no devices." : string.Join(Environment.NewLine, devices.Select(d =>
                    $"[{d.Index}] {d.Name} — {d.Vendor}, type {d.Type}, {d.Leds.Count} LEDs, modes: {string.Join(", ", d.Modes.Select(m => m.Name))}, active: {d.ActiveModeName}, serial {d.Serial}"));
            }
            catch (Exception ex) { _logBox.Text = ex.Message; }
        };
        page.Controls.Add(_logBox);
        page.Controls.Add(scan);
        page.Controls.Add(_diagnostics);
        return page;
    }

    // MARK: Small control helpers

    private static FlowLayoutPanel Column(Control parent)
    {
        var p = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(12) };
        parent.Controls.Add(p);
        return p;
    }

    private static FlowLayoutPanel Row(Control parent)
    {
        var r = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = new Padding(0, 4, 0, 4) };
        parent.Controls.Add(r);
        return r;
    }

    private static Label Bold(string text) => new() { Text = text, AutoSize = true, Font = new Font("Segoe UI Semibold", 10.5f), Margin = new Padding(0, 12, 0, 4) };
    private static Label Wrap(string text) => new() { Text = text, AutoSize = true, MaximumSize = new Size(720, 0), ForeColor = SystemColors.GrayText };

    private void Header(string text) => _effectOptions.Controls.Add(Bold(text));
    private void Note(string text) => _effectOptions.Controls.Add(Wrap(text));

    private void Slider(string title, double min, double max, Func<double> get, Action<double> set, Func<double, string> format)
    {
        var row = Row(_effectOptions);
        var label = new Label { Text = title, Width = 170, Padding = new Padding(0, 6, 0, 0) };
        var value = new Label { Width = 80, Padding = new Padding(0, 6, 0, 0) };
        var bar = new TrackBar { Minimum = 0, Maximum = 1000, TickStyle = TickStyle.None, Width = 300, AutoSize = false, Height = 30 };
        bar.Value = (int)Math.Round(Math.Clamp((get() - min) / (max - min), 0, 1) * 1000);
        value.Text = format(get());
        bar.ValueChanged += (_, _) =>
        {
            double v = min + (max - min) * bar.Value / 1000.0;
            set(v);
            value.Text = format(v);
            SettingsChanged();
        };
        row.Controls.AddRange([label, bar, value]);
    }

    private void Check(string title, Func<bool> get, Action<bool> set)
    {
        var box = new CheckBox { Text = title, AutoSize = true, Checked = get() };
        box.CheckedChanged += (_, _) => { set(box.Checked); SettingsChanged(); };
        _effectOptions.Controls.Add(box);
    }

    private void Choice(string title, string[] options, int selected, Action<int> set)
    {
        var row = Row(_effectOptions);
        var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300 };
        box.Items.AddRange(options);
        if (options.Length > 0) box.SelectedIndex = Math.Clamp(selected, 0, options.Length - 1);
        box.SelectedIndexChanged += (_, _) => { set(box.SelectedIndex); SettingsChanged(); };
        row.Controls.AddRange([new Label { Text = title, Width = 170, Padding = new Padding(0, 6, 0, 0) }, box]);
    }

    private void ColourButton(string title, Func<ColorValue> get, Action<ColorValue> set)
    {
        var row = Row(_effectOptions);
        var swatch = new Button { Width = 90, Height = 28, FlatStyle = FlatStyle.Flat, BackColor = ToColor(get()) };
        swatch.Click += (_, _) =>
        {
            using var dlg = new ColorDialog { Color = ToColor(get()), FullOpen = true };
            if (dlg.ShowDialog(this) != DialogResult.OK) return;
            set(new ColorValue(dlg.Color.R / 255.0, dlg.Color.G / 255.0, dlg.Color.B / 255.0));
            swatch.BackColor = dlg.Color;
            SettingsChanged();
        };
        row.Controls.AddRange([new Label { Text = title, Width = 170, Padding = new Padding(0, 6, 0, 0) }, swatch]);
    }

    private static Color ToColor(ColorValue c) => Color.FromArgb((int)(c.R * 255 + 0.5), (int)(c.G * 255 + 0.5), (int)(c.B * 255 + 0.5));

    // MARK: Profiles

    private void LoadProfiles()
    {
        _loading = true;
        _profileBox.Items.Clear();
        foreach (var p in _library.Profiles) _profileBox.Items.Add(p.Name);
        _profileBox.SelectedIndex = Math.Max(0, _library.Profiles.IndexOf(_library.Active!));
        _loading = false;
        LoadEffectList();
    }

    private void LoadEffectList()
    {
        _loading = true;
        _effectList.SelectedIndex = (int)Settings.Effect;
        _loading = false;
        BuildEffectOptions();
        UpdateScreenSampler();
    }

    private void DuplicateProfile()
    {
        var src = _library.Active!;
        var p = new LightingProfile { Name = $"{src.Name} copy", Settings = src.Settings.Copy() };
        _library.Profiles.Add(p);
        _library.ActiveId = p.Id;
        LoadProfiles();
        SettingsChanged();
    }

    private void RenameProfile()
    {
        var p = _library.Active!;
        var name = Prompt("Rename profile", p.Name);
        if (string.IsNullOrWhiteSpace(name)) return;
        p.Name = name.Trim();
        LoadProfiles();
        SettingsChanged();
    }

    private void DeleteProfile()
    {
        if (_library.Profiles.Count <= 1) return;
        var p = _library.Active!;
        if (MessageBox.Show($"Delete the profile “{p.Name}”?", "BeatRGB", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        _library.Profiles.Remove(p);
        _library.ActiveId = _library.Profiles[0].Id;
        LoadProfiles();
        SettingsChanged();
    }

    private string? Prompt(string title, string value)
    {
        using var f = new Form { Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(360, 90), MaximizeBox = false, MinimizeBox = false };
        var box = new TextBox { Text = value, Left = 12, Top = 12, Width = 336 };
        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Left = 192, Top = 50 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Left = 273, Top = 50 };
        f.Controls.AddRange([box, ok, cancel]);
        f.AcceptButton = ok; f.CancelButton = cancel;
        return f.ShowDialog(this) == DialogResult.OK ? box.Text : null;
    }

    // MARK: State plumbing

    private void SettingsChanged()
    {
        if (_loading) return;
        PushSettings();
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void PushSettings() => _engine.Update(Settings);

    private void PrefsChanged()
    {
        _prefsStore.Save(_prefs);
        _engine.Configure(_prefs.EngineConfig);
    }

    private async void RefreshDevices()
    {
        List<RGBDevice> devices;
        try { devices = await _engine.ScanAsync(); }
        catch { devices = []; }
        _loading = true;
        _deviceBox.Items.Clear();
        _deviceBox.Items.Add("Automatic — first RGB keyboard");
        var names = devices.Select(d => d.Name).ToList();
        if (_prefs.DeviceName is { } saved && !names.Contains(saved)) names.Add(saved);
        foreach (var n in names.Distinct()) _deviceBox.Items.Add(n);
        _deviceBox.SelectedIndex = _prefs.DeviceName is { } pick ? Math.Max(0, _deviceBox.Items.IndexOf(pick)) : 0;
        _loading = false;
    }

    private void ToggleSync()
    {
        if (_syncing) StopSync(); else StartSync();
    }

    private void StartSync()
    {
        if (_syncing) return;
        _syncing = true;
        _audio.Start();
        _engine.SetAudioSource(_audio.Ring);
        UpdateScreenSampler();
        _engine.Start();
        _syncButton.Text = "Stop sync";
    }

    private async void StopSync()
    {
        if (!_syncing) return;
        _syncing = false;
        _syncButton.Text = "Start sync";
        _engine.SetAudioSource(null);
        _audio.Stop();
        _screen.Stop();
        await _engine.StopAsync();
    }

    private void UpdateScreenSampler(bool restart = false)
    {
        bool wanted = _syncing && Settings.Effect.UsesScreen();
        if (wanted && (restart || _screen.Latest == null)) _screen.Start(Settings.ScreenDisplayIndex);
        else if (!wanted) _screen.Stop();
    }

    private void OnSnapshot(EngineSnapshot s)
    {
        _snapshot = s;
        _preview.Display(s.Layout, s.Frame);
        string device = s.Device is { } d ? $"{d.Name} · {s.LedCount} LEDs" : "no keyboard";
        _status.Text = s.Connection switch
        {
            ConnectionStatus.Connected => $"● {device} · {s.Fps:0} fps",
            ConnectionStatus.Connecting => "Connecting to OpenRGB…",
            ConnectionStatus.Failed => $"⚠ {s.LastError}",
            _ => s.Running ? "Waiting for OpenRGB…" : "Stopped",
        };
        _tray.Text = s.Running ? "BeatRGB — syncing" : "BeatRGB";
        _diagnostics.Text =
            $"Connection: {s.Connection}{(s.ConnectionInfo.Length > 0 ? $" · {s.ConnectionInfo}" : "")}\n" +
            $"Keyboard: {(s.Device is { } k ? $"{k.Name} ({k.Vendor}), {s.LedCount} LEDs on a {s.Layout.Rows}×{s.Layout.Cols} map, {s.Mode} mode" : _prefs.DeviceName ?? "first RGB keyboard OpenRGB reports")}\n" +
            $"Audio: {_audioState} · level {s.Features.RmsDB:0} dBFS{(s.Features.IsSilent ? " (silent)" : "")}\n" +
            $"Screen: {_screen.Description}\n" +
            $"Update rate: {s.Fps:0.0} fps (target {s.TargetFps:0}) · round trip {s.LatencyMs:0.0} ms · {s.FramesSent} frames sent";
        // Newest first; only rewrite the box when a line was added, and leave scan results alone.
        string newest = s.Log.Count > 0 ? s.Log[^1] : "";
        if (newest != _lastLogLine && !_logBox.Focused && !_logBox.Text.StartsWith("[", StringComparison.Ordinal))
        {
            _lastLogLine = newest;
            _logBox.Text = string.Join(Environment.NewLine, s.Log.Reverse());
        }
    }

    // MARK: Window and tray

    private void ShowWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_quitting && e.CloseReason == CloseReason.UserClosing)
        {
            // Keep running in the notification area; Quit from the tray menu exits.
            e.Cancel = true;
            Hide();
            return;
        }
        if (!_quitting)
        {
            // Signing out or shutting down: hand the keyboard back before Windows ends the process.
            _profileStore.Save(_library);
            _engine.StopAsync().Wait(TimeSpan.FromSeconds(2));
            _tray.Visible = false;
        }
        base.OnFormClosing(e);
    }

    private async void Quit()
    {
        _quitting = true;
        _saveTimer.Stop();
        _profileStore.Save(_library);
        if (_syncing) StopSync();
        await _engine.StopAsync();
        _tray.Visible = false;
        _engine.Dispose();
        _audio.Dispose();
        _screen.Dispose();
        Application.Exit();
    }
}
