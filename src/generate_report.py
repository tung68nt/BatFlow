import os, sys, subprocess, re, datetime, json, html as html_lib

def get_battery_and_processes():
    # 1. Official Apple Battery Health from system_profiler
    sp = subprocess.run(['system_profiler', 'SPPowerDataType'], capture_output=True, text=True).stdout
    max_cap_apple = re.search(r'Maximum Capacity:\s*(\d+)%', sp)
    apple_health_pct = int(max_cap_apple.group(1)) if max_cap_apple else 80
    apple_deg_pct = 100 - apple_health_pct

    # AC Charger Info from system_profiler
    m_connected = re.search(r'Connected:\s*(Yes|No)', sp)
    ac_connected = (m_connected.group(1) == 'Yes') if m_connected else False

    m_watt = re.search(r'Wattage \(W\):\s*(\d+)', sp)
    adapter_rated_w = int(m_watt.group(1)) if m_watt else 0

    m_charging = re.search(r'Charging:\s*(Yes|No)', sp)
    is_charging_sp = (m_charging.group(1) == 'Yes') if m_charging else False

    # 2. ioreg query for hardware details
    ioreg_out = subprocess.run(['ioreg', '-r', '-c', 'AppleSmartBattery'], capture_output=True, text=True).stdout
    
    def extract_val(pattern, text):
        m = re.search(pattern, text)
        return m.group(1).strip() if m else None

    bat_data_match = re.search(r'\"BatteryData\"\s*=\s*\{([^}]+)\}', ioreg_out)
    bat_dict = {}
    if bat_data_match:
        for pair in bat_data_match.group(1).split(','):
            if '=' in pair:
                k, v = pair.split('=', 1)
                k = k.strip().replace('"', '')
                bat_dict[k] = v.strip().replace('"', '')

    full_cap = int(bat_dict.get('FullChargeCapacity', 4707))
    nominal_cap = int(bat_dict.get('NominalChargeCapacity', 4867))
    design_cap = int(bat_dict.get('DesignCapacity', 6075))
    remaining_cap = int(bat_dict.get('RemainingCapacity', 1088))
    cycle_count = int(extract_val(r'\"CycleCount\"\s*=\s*(\d+)', ioreg_out) or 780)
    
    # Raw hardware calculation
    actual_cap = full_cap if full_cap > 0 else 4707
    raw_health_pct = round((actual_cap / design_cap) * 100, 1) if design_cap else 77.5
    raw_deg_pct = round(100.0 - raw_health_pct, 1)

    raw_v = int(extract_val(r'\"AppleRawBatteryVoltage\"\s*=\s*(\d+)', ioreg_out) or 11000)
    voltage = raw_v / 1000.0

    raw_amp = int(extract_val(r'\"Amperage\"\s*=\s*(\d+)', ioreg_out) or 0)
    if raw_amp > (1 << 63):
        amperage = raw_amp - (1 << 64)
    else:
        amperage = raw_amp

    bat_net_watts = (voltage * (amperage / 1000.0))

    raw_temp = int(extract_val(r'\"Temperature\"\s*=\s*(\d+)', ioreg_out) or 3100)
    temp = raw_temp / 100.0 if raw_temp > 1000 else raw_temp

    is_charging_ioreg = extract_val(r'\"IsCharging\"\s*=\s*(Yes|No)', ioreg_out) == 'Yes'
    ext_connected_ioreg = extract_val(r'\"ExternalConnected\"\s*=\s*(Yes|No)', ioreg_out) == 'Yes'

    ac_online = ac_connected or ext_connected_ioreg
    charging_now = is_charging_sp or is_charging_ioreg or (amperage > 50)

    # PowerTelemetryData for system load
    pt_match = re.search(r'\"PowerTelemetryData\"\s*=\s*\{([^}]+)\}', ioreg_out)
    pt = {}
    if pt_match:
        for pair in pt_match.group(1).split(','):
            if '=' in pair:
                k, v = pair.split('=', 1)
                try:
                    pt[k.strip().replace('"', '')] = int(v.strip().replace('"', ''))
                except:
                    pass

    sys_load_w = pt.get('SystemLoad', 0) / 1000.0
    if sys_load_w <= 0.5:
        sys_load_w = abs(bat_net_watts) if not ac_online else 6.0

    if ac_online:
        if adapter_rated_w > 0:
            adapter_in_w = float(adapter_rated_w)
        else:
            adapter_in_w = max(sys_load_w + bat_net_watts, 20.0)
    else:
        adapter_in_w = 0.0

    # Detect active port via AppleHPMDevice
    ioreg_hpm = subprocess.run(['ioreg', '-r', '-c', 'AppleHPMDevice', '-l'], capture_output=True, text=True).stdout
    active_port_name = 'Chưa cắm sạc'
    
    if ac_online:
        if 'Port-MagSafe' in ioreg_hpm and ('"IOAccessoryActivePowerMode" = 2' in ioreg_hpm or '"IOAccessoryActivePowerMode" = 3' in ioreg_hpm):
            active_port_name = 'Cổng MagSafe 3 (Cạnh trái)'
        elif 'Port-USB-C@3' in ioreg_hpm and '"IOAccessoryActivePowerMode" = 3' in ioreg_hpm:
            active_port_name = 'Cổng Type-C (Cạnh phải)'
        elif 'Port-USB-C@1' in ioreg_hpm and '"IOAccessoryActivePowerMode" = 3' in ioreg_hpm:
            active_port_name = 'Cổng Type-C 1 (Cạnh trái - Phía sau)'
        elif 'Port-USB-C@2' in ioreg_hpm and '"IOAccessoryActivePowerMode" = 3' in ioreg_hpm:
            active_port_name = 'Cổng Type-C 2 (Cạnh trái - Phía trước)'
        else:
            active_port_name = 'Cổng sạc Type-C / USB-PD'

    # 3. pmset -g batt
    batt_out = subprocess.run(['pmset', '-g', 'batt'], capture_output=True, text=True).stdout
    pct_m = re.search(r'(\d+)%', batt_out)
    percent = int(pct_m.group(1)) if pct_m else 25
    
    rem_m = re.search(r'(\d+:\d+) remaining', batt_out)
    time_remaining = rem_m.group(1) if rem_m else ('Cắm sạc' if charging_now else 'Đang tính toán')

    if charging_now:
        state_str = 'Đang sạc pin'
        state_color = '#22c55e'
    elif ac_online:
        state_str = 'Nguồn điện Adapter (Đầy)'
        state_color = '#38bdf8'
    else:
        state_str = 'Đang dùng pin (Xả pin)'
        state_color = '#f59e0b'

    # 4. Top Energy/CPU processes
    ps_out = subprocess.run(['ps', '-A', '-o', 'pid,%cpu,%mem,comm'], capture_output=True, text=True).stdout
    lines = ps_out.splitlines()[1:]

    procs = []
    for l in lines:
        parts = l.strip().split(None, 3)
        if len(parts) == 4:
            try:
                pid, cpu, mem, comm = parts[0], float(parts[1]), float(parts[2]), parts[3]
                procs.append({'pid': pid, 'cpu': cpu, 'mem': mem, 'comm': comm})
            except:
                pass

    def get_friendly_info(comm):
        comm_lower = comm.lower()
        if 'google chrome' in comm_lower:
            return ('Google Chrome', 'Trình duyệt web')
        elif 'antigravity ide' in comm_lower or 'electron' in comm_lower:
            return ('Antigravity IDE', 'Lập trình & Agent AI')
        elif 'windowserver' in comm_lower:
            return ('WindowServer', 'Quản lý đồ họa macOS')
        elif 'tailscale' in comm_lower or 'nehelper' in comm_lower or 'nesessionmanager' in comm_lower:
            return ('Tailscale VPN', 'Mạng nội bộ bảo mật')
        elif 'zalo' in comm_lower:
            return ('Zalo', 'Tin nhắn & gọi thoại')
        elif 'claude' in comm_lower:
            return ('Claude Desktop', 'Trợ lý AI')
        elif 'fpt chat' in comm_lower:
            return ('FPT Chat', 'Tin nhắn nội bộ')
        elif 'spotlight' in comm_lower or 'mds' in comm_lower or 'mdworker' in comm_lower:
            return ('Spotlight', 'Đánh chỉ mục ổ cứng')
        elif 'kernel_task' in comm_lower:
            return ('kernel_task', 'Hạt nhân hệ điều hành')
        elif 'coreaudiod' in comm_lower:
            return ('Core Audio', 'Xử lý âm thanh')
        elif 'docker' in comm_lower or 'com.docker' in comm_lower:
            return ('Docker', 'Môi trường container')
        elif 'finder' in comm_lower:
            return ('Finder', 'Quản lý tệp tin')
        else:
            return (comm.split('/')[-1], 'Tiến trình nền')

    aggregated = {}
    for p in procs:
        name, cat = get_friendly_info(p['comm'])
        if name not in aggregated:
            aggregated[name] = {'name': name, 'cat': cat, 'cpu': 0.0, 'mem': 0.0, 'count': 0}
        aggregated[name]['cpu'] += p['cpu']
        aggregated[name]['mem'] += p['mem']
        aggregated[name]['count'] += 1

    top_apps = sorted(aggregated.values(), key=lambda x: (x['cpu'] + x['mem']*0.5), reverse=True)[:8]

    # 5. Timeline
    today_str = datetime.date.today().strftime('%Y-%m-%d')
    try:
        pmset_proc = subprocess.run(['pmset', '-g', 'log'], capture_output=True)
        pmset_log = pmset_proc.stdout.decode('utf-8', errors='replace') if pmset_proc.stdout else ''
    except Exception:
        pmset_log = ''
    
    events = []
    screen_events = []

    for line in pmset_log.splitlines():
        if not line.startswith(today_str):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        time_part = parts[1]

        if 'Display is turned on' in line:
            screen_events.append(('ON', time_part))
            events.append({'time': time_part, 'type': 'on', 'title': 'Bật màn hình', 'detail': 'Bắt đầu tính thời gian onscreen'})
        elif 'Display is turned off' in line:
            screen_events.append(('OFF', time_part))
            events.append({'time': time_part, 'type': 'off', 'title': 'Tắt màn hình', 'detail': 'Màn hình tắt tạm thời'})
        elif 'Entering Sleep' in line:
            screen_events.append(('OFF', time_part))
            reason = 'Gập nắp' if 'Clamshell' in line else ('Nhàn rỗi' if 'Idle' in line else 'Bảo trì')
            events.append({'time': time_part, 'type': 'sleep', 'title': 'Chuyển sang chế độ ngủ', 'detail': f'Trạng thái: {reason}'})
        elif 'Wake from' in line or 'lidopen' in line:
            events.append({'time': time_part, 'type': 'wake', 'title': 'Mở nắp máy / thức dậy', 'detail': 'Kích hoạt phiên làm việc'})

    total_screen_sec = 0
    last_on = None
    for state, t_str in screen_events:
        t_obj = datetime.datetime.strptime(f'{today_str} {t_str}', '%Y-%m-%d %H:%M:%S')
        if state == 'ON':
            last_on = t_obj
        elif state == 'OFF' and last_on:
            total_screen_sec += (t_obj - last_on).total_seconds()
            last_on = None

    if last_on:
        total_screen_sec += (datetime.datetime.now() - last_on).total_seconds()

    total_h = int(total_screen_sec // 3600)
    total_m = int((total_screen_sec % 3600) // 60)
    total_s = int(total_screen_sec % 60)

    # Session calculation (from ~20:01)
    session_on_sec = 0
    session_start_time = '20:01:06'
    last_session_start = None
    for state, t_str in screen_events:
        if t_str >= '19:30:00':
            t_obj = datetime.datetime.strptime(f'{today_str} {t_str}', '%Y-%m-%d %H:%M:%S')
            if state == 'ON':
                if not last_session_start:
                    session_start_time = t_str
                last_session_start = t_obj
            elif state == 'OFF' and last_session_start:
                session_on_sec += (t_obj - last_session_start).total_seconds()
                last_session_start = None
    if last_session_start:
        session_on_sec += (datetime.datetime.now() - last_session_start).total_seconds()

    sess_h = int(session_on_sec // 3600)
    sess_m = int((session_on_sec % 3600) // 60)
    sess_s = int(session_on_sec % 60)

    return {
        'percent': percent,
        'state_str': state_str,
        'state_color': state_color,
        'time_remaining': time_remaining,
        'apple_health_pct': apple_health_pct,
        'apple_deg_pct': apple_deg_pct,
        'raw_health_pct': raw_health_pct,
        'raw_deg_pct': raw_deg_pct,
        'actual_cap': actual_cap,
        'cycle_count': cycle_count,
        'nominal_cap': nominal_cap,
        'full_cap': full_cap,
        'design_cap': design_cap,
        'remaining_cap': remaining_cap,
        'ac_online': ac_online,
        'charging_now': charging_now,
        'active_port_name': active_port_name,
        'adapter_rated_w': adapter_rated_w,
        'adapter_in_w': round(adapter_in_w, 1),
        'sys_load_w': round(sys_load_w, 1),
        'bat_net_watts': round(bat_net_watts, 1),
        'voltage': round(voltage, 2),
        'amperage': amperage,
        'temp': round(temp, 1),
        'total_screen_sec': int(total_screen_sec),
        'session_on_sec': int(session_on_sec),
        'total_screen_time': f'{total_h}h : {total_m:02d}m : {total_s:02d}s',
        'session_screen_time': f'{sess_h}h : {sess_m:02d}m : {sess_s:02d}s',
        'session_start_time': session_start_time,
        'top_apps': top_apps,
        'events': events[-8:][::-1],
        'generated_at': datetime.datetime.now().strftime('%H:%M:%S')
    }

def make_dynamic_battery_svg(pct, is_charging=False, size=58):
    # Dynamic color scale from green (100%) to red (<20%)
    if pct >= 70:
        c1, c2 = '#10b981', '#06b6d4'
        glow_color = 'rgba(16, 185, 129, 0.4)'
    elif pct >= 40:
        c1, c2 = '#10b981', '#84cc16'
        glow_color = 'rgba(132, 204, 22, 0.35)'
    elif pct >= 20:
        c1, c2 = '#f59e0b', '#eab308'
        glow_color = 'rgba(245, 158, 11, 0.4)'
    else:
        c1, c2 = '#ef4444', '#f43f5e'
        glow_color = 'rgba(239, 68, 68, 0.5)'

    # Fluid height calculation (expanded cylinder height 60px, from y=20 to y=80)
    cyl_top = 20
    cyl_h = 60
    fluid_h = max(5, int(cyl_h * (pct / 100.0)))
    fluid_y = cyl_top + (cyl_h - fluid_h)

    bolt_or_text = '''
    <path d="M48 38 L54 38 L50 54 L56 54 L46 68 L48 50 L42 50 Z" fill="white" opacity="0.95" filter="drop-shadow(0 0 4px rgba(255,255,255,0.6))"/>
    ''' if is_charging else f'''
    <text x="50" y="57" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="20" font-weight="800" fill="white" text-anchor="middle" opacity="0.98" filter="drop-shadow(0 1px 3px rgba(0,0,0,0.6))">{pct}%</text>
    '''

    svg = f'''<svg width="{size}" height="{size}" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
        <defs>
            <linearGradient id="dynBgGrad" x1="0" y1="0" x2="100" y2="100">
                <stop offset="0%" stop-color="#1E1E24"/>
                <stop offset="100%" stop-color="#0A0A0D"/>
            </linearGradient>
            <linearGradient id="dynFluidGrad" x1="0" y1="1" x2="0" y2="0">
                <stop offset="0%" stop-color="{c1}"/>
                <stop offset="100%" stop-color="{c2}"/>
            </linearGradient>
            <linearGradient id="metalGrad" x1="0" y1="0" x2="1" y2="0">
                <stop offset="0%" stop-color="#71717A"/>
                <stop offset="50%" stop-color="#D4D4D8"/>
                <stop offset="100%" stop-color="#52525B"/>
            </linearGradient>
            <filter id="dynGlow" x="-20%" y="-20%" width="140%" height="140%">
                <feGaussianBlur stdDeviation="3" result="blur"/>
                <feComposite in="SourceGraphic" in2="blur" operator="over"/>
            </filter>
        </defs>

        <!-- Squircle Base -->
        <rect class="svg-squircle" x="2" y="2" width="96" height="96" rx="22"/>

        <!-- Battery Nipple Cap -->
        <rect x="40" y="11" width="20" height="7" rx="3" fill="url(#metalGrad)" stroke="#3F3F46" stroke-width="1"/>

        <!-- Outer Frosted Glass Cylinder -->
        <rect class="svg-cylinder" x="21" y="17" width="58" height="66" rx="12" stroke-width="1.5" opacity="0.9"/>

        <!-- Fluid Level -->
        <g filter="url(#dynGlow)">
            <rect x="23" y="{fluid_y}" width="54" height="{fluid_h}" rx="10" fill="url(#dynFluidGrad)"/>
        </g>

        <!-- Glass Reflection Highlights -->
        <path d="M25 21 C25 21 33 19 50 19 C67 19 75 21 75 21" stroke="rgba(255,255,255,0.3)" stroke-width="1.5" stroke-linecap="round"/>
        <line x1="25" y1="23" x2="25" y2="79" stroke="rgba(255,255,255,0.18)" stroke-width="1.5" stroke-linecap="round"/>

        <!-- Center Indicator (Bolt or %) -->
        {bolt_or_text}
    </svg>'''
    return svg

def generate_html(data):
    # Determine Status Capsule styling & icon
    if data['charging_now']:
        status_theme_class = "capsule-charging"
        status_icon = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>'
        eta_title = "đầy pin"
    elif data['ac_online']:
        status_theme_class = "capsule-hold"
        status_icon = '<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1.5"/><rect x="14" y="4" width="4" height="16" rx="1.5"/></svg>'
        eta_title = "trạng thái"
    else:
        status_theme_class = "capsule-discharging"
        status_icon = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="2" y="6" width="18" height="12" rx="3"/><path d="M22 10v4"/></svg>'
        eta_title = "còn lại"

    # App table rows with Apple style avatar badge & clean pill
    app_rows = ''
    for app in data['top_apps']:
        cpu = round(app.get('cpu', 0), 1)
        mem = round(app.get('mem', 0), 1)
        safe_name = html_lib.escape(str(app.get('name', '')))
        safe_cat = html_lib.escape(str(app.get('cat', '')))

        if cpu > 20 or mem > 20:
            badge_html = '<span class="status-badge badge-high">Cao</span>'
        elif cpu > 5 or mem > 5:
            badge_html = '<span class="status-badge badge-mid">Vừa</span>'
        else:
            badge_html = '<span class="status-badge badge-low">Thấp</span>'

        load_w = min(100, max(4, int(cpu * 1.4 + mem * 1.2)))
        initial_letter = safe_name[:1].upper() if safe_name else "A"

        app_rows += f"""
        <tr>
            <td class="td-app">
                <div class="app-icon-badge">{initial_letter}</div>
                <div class="app-meta">
                    <span class="app-title">{safe_name}</span>
                    <span class="app-type">{safe_cat}</span>
                </div>
            </td>
            <td class="td-mono">{cpu}%</td>
            <td class="td-mono">{mem}%</td>
            <td class="td-mono td-proc">{app.get('count', 1)}</td>
            <td class="td-status">{badge_html}</td>
            <td class="td-meter">
                <div class="meter-track"><div class="meter-fill" style="width: {load_w}%;"></div></div>
            </td>
        </tr>
        """

    # Timeline rows
    timeline_rows = ''
    for ev in data['events']:
        dot_color = '#8e8e93'
        if ev.get('type') == 'on':
            dot_color = '#34C759'
        elif ev.get('type') == 'sleep':
            dot_color = '#AF52DE'
        elif ev.get('type') == 'wake':
            dot_color = '#FF9500'

        safe_ev_time = html_lib.escape(str(ev.get('time', '')))
        safe_ev_title = html_lib.escape(str(ev.get('title', '')))
        safe_ev_detail = html_lib.escape(str(ev.get('detail', '')))

        timeline_rows += f"""
        <div class="tl-row">
            <div class="tl-time">{safe_ev_time}</div>
            <div class="tl-indicator"><span class="tl-dot" style="background: {dot_color};"></span></div>
            <div class="tl-content">
                <span class="tl-title">{safe_ev_title}</span>
                <span class="tl-detail">{safe_ev_detail}</span>
            </div>
        </div>
        """

    # Dynamic Battery Icon (scales from Green 100% down to Red <20%)
    dynamic_battery_svg = make_dynamic_battery_svg(data['percent'], data['charging_now'], size=54)

    # Power Delivery / Flow Logic
    if data['ac_online']:
        sys_w = data['sys_load_w']
        bat_w = data['bat_net_watts']
        adapter_w = data['adapter_in_w']

        if bat_w >= 0:
            bat_flow_label = f"+{bat_w} W"
            bat_flow_desc = "Đang nạp vào pin (Dương)"
            bat_flow_color = "#34C759"
            alert_box = ""
        else:
            bat_flow_label = f"{bat_w} W"
            bat_flow_desc = "Pin đang xả bù (Thâm hụt)"
            bat_flow_color = "#FF3B30"
            alert_box = f"""
            <div class="power-warning">
                <b>Cảnh báo thâm hụt:</b> Củ sạc không đủ cấp cho công suất máy ({sys_w}W). Pin đang phải bù thêm {abs(bat_w)}W. 
                Hãy giảm độ sáng màn hình hoặc đóng bớt ứng dụng nặng để dòng sạc dương trở lại.
            </div>
            """

        total_bar = max(adapter_w, sys_w + max(0, bat_w))
        sys_pct = min(100, int((sys_w / total_bar) * 100)) if total_bar > 0 else 50
        bat_pct = min(100 - sys_pct, int((max(0, bat_w) / total_bar) * 100)) if total_bar > 0 else 50

        power_flow_html = f"""
        <div class="active-connection-card">
            <div class="conn-icon-wrap">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
            </div>
            <div class="conn-text">
                <span class="conn-title">Đang tiếp nhận nguồn: <b>{data.get('active_port_name', 'Cổng sạc Type-C')}</b></span>
                <span class="conn-spec">Chuẩn giao thức USB-Power Delivery • Công suất cấp <b>{adapter_w} W</b></span>
            </div>
            <div class="conn-badge">
                <span class="pulse-dot"></span>
                <span>Đang kết nối</span>
            </div>
        </div>

        <div class="flow-grid">
            <div class="flow-card">
                <span class="fl-label">Công suất củ sạc</span>
                <div class="fl-val-row">
                    <span class="fl-val">{adapter_w}</span>
                    <span class="fl-unit">W</span>
                </div>
                <span class="fl-sub">Nguồn cấp từ adapter</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Máy đang tiêu thụ</span>
                <div class="fl-val-row">
                    <span class="fl-val">{sys_w}</span>
                    <span class="fl-unit">W</span>
                </div>
                <span class="fl-sub">Tải phần cứng hệ thống</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Dòng nạp vào pin</span>
                <div class="fl-val-row">
                    <span class="fl-val" style="color: {bat_flow_color};">{bat_flow_label}</span>
                </div>
                <span class="fl-sub">{bat_flow_desc}</span>
            </div>
        </div>

        <div class="flow-meter-container">
            <div class="flow-meter-header">
                <span>Phân bổ điện năng thời gian thực</span>
                <div class="flow-meter-legend">
                    <span class="leg-item"><span class="leg-dot dot-sys"></span>Máy dùng {sys_w}W ({sys_pct}%)</span>
                    <span class="leg-item"><span class="leg-dot dot-bat"></span>Nạp pin {max(0, bat_w)}W ({bat_pct}%)</span>
                </div>
            </div>
            <div class="flow-meter-bar">
                <div class="flow-seg-sys" style="width: {sys_pct}%;"></div>
                <div class="flow-seg-bat" style="width: {bat_pct}%;"></div>
            </div>
        </div>
        {alert_box}
        """
    else:
        sys_w = data['sys_load_w']
        power_flow_html = f"""
        <div class="active-connection-card conn-idle">
            <div class="conn-icon-wrap idle">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="6" width="18" height="12" rx="3"/><path d="M22 10v4"/></svg>
            </div>
            <div class="conn-text">
                <span class="conn-title">Nguồn cấp: <b>Đang sử dụng pin tích hợp</b></span>
                <span class="conn-spec">Chưa cắm sạc ngoài • Thiết bị đang xả pin thuần túy</span>
            </div>
            <div class="conn-badge badge-idle">
                <span>Dùng pin</span>
            </div>
        </div>

        <div class="flow-grid">
            <div class="flow-card">
                <span class="fl-label">Trạng thái nguồn</span>
                <div class="fl-val-row">
                    <span class="fl-val" style="color: #FF9500;">Dùng Pin</span>
                </div>
                <span class="fl-sub">Không có củ sạc kết nối</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Máy đang tiêu thụ</span>
                <div class="fl-val-row">
                    <span class="fl-val">{sys_w}</span>
                    <span class="fl-unit">W</span>
                </div>
                <span class="fl-sub">Tải phần cứng hệ thống</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Dòng xả từ pin</span>
                <div class="fl-val-row">
                    <span class="fl-val" style="color: #FF9500;">{data['bat_net_watts']}</span>
                    <span class="fl-unit">W</span>
                </div>
                <span class="fl-sub">Xả năng lượng thực tế</span>
            </div>
        </div>
        """

    # Check port connection status
    port_name = data.get('active_port_name', '')
    is_left_active = "Trái" in port_name or "USB-C" in port_name or "MagSafe" in port_name
    is_right_active = "Phải" in port_name

    active_tag_left = '<span class="port-chip-badge">● Đang sạc 65W</span>' if is_left_active else ''
    active_class_left = 'port-chip-active' if is_left_active else ''
    active_class_right = 'port-chip-active' if is_right_active else ''

    # Read base64 icon safely
    icon_b64 = ""
    icon_path = os.path.join(os.path.dirname(__file__), '..', 'resources', 'battery_icon.png')
    if not os.path.exists(icon_path):
        icon_path = os.path.expanduser('~/Code/BatFlow/resources/battery_icon.png')
    if os.path.exists(icon_path):
        import base64
        with open(icon_path, 'rb') as f:
            icon_b64 = base64.b64encode(f.read()).decode('utf-8')

    html_out = f"""<!DOCTYPE html>
<html lang="vi">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>BatFlow • Báo Cáo Phân Tích Dòng Điện & Pin</title>
    <link rel="icon" type="image/png" href="data:image/png;base64,{icon_b64}">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {{
            --bg: #F5F5F7;
            --surface: #FFFFFF;
            --surface-sub: #FBFBFD;
            --surface-elevated: #FFFFFF;
            --border: rgba(0, 0, 0, 0.08);
            --border-sub: rgba(0, 0, 0, 0.04);
            --text-1: #1D1D1F;
            --text-2: #48484A;
            --text-3: #86868B;
            --card-shadow: 0 4px 20px rgba(0, 0, 0, 0.03), 0 1px 3px rgba(0, 0, 0, 0.02);
            --apple-green: #34C759;
            --apple-blue: #0071E3;
            --apple-orange: #FF9500;
            --apple-red: #FF3B30;
            --font-sans: 'Inter', -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', sans-serif;
        }}
        @media (prefers-color-scheme: dark) {{
            :root {{
                --bg: #000000;
                --surface: #1C1C1E;
                --surface-sub: #2C2C2E;
                --surface-elevated: #242426;
                --border: rgba(255, 255, 255, 0.12);
                --border-sub: rgba(255, 255, 255, 0.06);
                --text-1: #F5F5F7;
                --text-2: #A1A1A6;
                --text-3: #636366;
                --card-shadow: 0 4px 24px rgba(0, 0, 0, 0.4);
                --apple-green: #30D158;
                --apple-blue: #0A84FF;
                --apple-orange: #FF9F0A;
                --apple-red: #FF453A;
            }}
        }}
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            -webkit-font-smoothing: antialiased;
        }}
        body {{
            background-color: var(--bg);
            color: var(--text-1);
            font-family: var(--font-sans);
            font-size: 13px;
            line-height: 1.45;
            padding: 32px 28px 48px 28px;
            display: flex;
            justify-content: center;
            transition: background-color 0.2s ease, color 0.2s ease;
        }}
        .shell {{
            max-width: 860px;
            width: 100%;
        }}

        /* Header (Apple Hardware Style) */
        header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 24px;
            padding-bottom: 18px;
            border-bottom: 1px solid var(--border);
            user-select: none;
        }}
        .header-left {{
            display: flex;
            align-items: center;
            gap: 14px;
        }}
        .brand-icon-wrap {{
            width: 54px;
            height: 54px;
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            transition: transform 0.2s cubic-bezier(0.16, 1, 0.3, 1);
        }}
        .brand-icon-wrap:hover {{
            transform: scale(1.05);
        }}
        .svg-squircle {{
            fill: #ffffff;
            stroke: var(--border);
            stroke-width: 1.5;
            filter: drop-shadow(0 2px 8px rgba(0, 0, 0, 0.05));
        }}
        .svg-cylinder {{
            fill: #f4f4f7;
            stroke: #d1d1d6;
        }}
        @media (prefers-color-scheme: dark) {{
            .svg-squircle {{
                fill: url(#dynBgGrad);
                stroke: #2E2E36;
                filter: none;
            }}
            .svg-cylinder {{
                fill: #141418;
                stroke: #3F3F46;
            }}
        }}
        .device-info {{
            display: flex;
            flex-direction: column;
            gap: 2px;
        }}
        .device-name-row {{
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .device-name {{
            font-size: 16px;
            font-weight: 600;
            letter-spacing: -0.2px;
            color: var(--text-1);
        }}
        .device-chip {{
            font-size: 12.5px;
            color: var(--text-3);
            font-weight: 400;
        }}
        .live-pill {{
            display: inline-flex;
            align-items: center;
            gap: 5px;
            padding: 2.5px 8px;
            background: rgba(52, 199, 89, 0.1);
            border-radius: 100px;
            font-size: 11px;
            color: var(--apple-green);
            font-weight: 500;
            font-variant-numeric: tabular-nums;
        }}
        .pulse-dot {{
            width: 5.5px;
            height: 5.5px;
            border-radius: 50%;
            background: var(--apple-green);
            box-shadow: 0 0 5px var(--apple-green);
            animation: pulse 1.6s infinite;
        }}
        @keyframes pulse {{
            0% {{ opacity: 1; transform: scale(1); }}
            50% {{ opacity: 0.35; transform: scale(0.85); }}
            100% {{ opacity: 1; transform: scale(1); }}
        }}
        .btn-sync {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: var(--surface);
            border: 1px solid var(--border);
            color: var(--text-2);
            padding: 6px 13px;
            border-radius: 8px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
            transition: all 0.15s ease;
        }}
        .btn-sync:hover {{
            background: var(--surface-sub);
            color: var(--text-1);
            border-color: rgba(0, 0, 0, 0.15);
        }}

        /* Hero Battery Card */
        .card-main {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 20px;
            padding: 26px 30px;
            margin-bottom: 24px;
            box-shadow: var(--card-shadow);
        }}
        .main-top {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 18px;
        }}
        .pct-group {{
            display: flex;
            align-items: center;
            gap: 14px;
        }}
        .pct-number {{
            font-size: 64px;
            font-weight: 700;
            letter-spacing: -2.5px;
            line-height: 1;
            color: var(--text-1);
            font-variant-numeric: tabular-nums;
        }}
        .status-capsule {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 12.5px;
            font-weight: 500;
        }}
        .capsule-charging {{
            background: rgba(52, 199, 89, 0.1);
            color: var(--apple-green);
        }}
        .capsule-hold {{
            background: rgba(0, 113, 227, 0.08);
            color: var(--apple-blue);
        }}
        .capsule-discharging {{
            background: rgba(0, 0, 0, 0.05);
            color: var(--text-2);
        }}
        @media (prefers-color-scheme: dark) {{
            .capsule-discharging {{
                background: rgba(255, 255, 255, 0.08);
                color: var(--text-2);
            }}
        }}
        .eta-group {{
            display: flex;
            flex-direction: column;
            align-items: flex-end;
            gap: 1px;
        }}
        .eta-label {{
            font-size: 11px;
            color: var(--text-3);
            font-weight: 500;
        }}
        .eta-val {{
            font-size: 14px;
            font-weight: 600;
            color: var(--text-1);
        }}

        /* Smooth Capsule Progress Bar */
        .battery-bar-track {{
            height: 8px;
            background: rgba(0, 0, 0, 0.05);
            border-radius: 100px;
            margin-bottom: 24px;
            overflow: hidden;
        }}
        @media (prefers-color-scheme: dark) {{
            .battery-bar-track {{
                background: rgba(255, 255, 255, 0.08);
            }}
        }}
        .battery-bar-fill {{
            height: 100%;
            background: linear-gradient(90deg, #34C759 0%, #30D158 100%);
            border-radius: 100px;
            transition: width 0.4s ease;
        }}

        /* Key Metrics Row */
        .stats-strip {{
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 18px;
            padding-top: 20px;
            border-top: 1px solid var(--border-sub);
        }}
        @media (max-width: 680px) {{
            .stats-strip {{ grid-template-columns: repeat(2, 1fr); }}
        }}
        .stat-item {{
            display: flex;
            flex-direction: column;
            gap: 3px;
        }}
        .st-label {{
            font-size: 11.5px;
            color: var(--text-3);
            font-weight: 500;
        }}
        .st-val {{
            font-size: 18.5px;
            font-weight: 600;
            letter-spacing: -0.5px;
            color: var(--text-1);
            font-variant-numeric: tabular-nums;
        }}
        .st-unit {{
            font-size: 13.5px;
            font-weight: 500;
            color: var(--text-3);
        }}
        .st-sub {{
            font-size: 11px;
            color: var(--text-3);
        }}

        /* Section Layouts */
        .section-wrap {{
            margin-bottom: 28px;
        }}
        .sec-head {{
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            margin-bottom: 12px;
            padding: 0 4px;
        }}
        .sec-title {{
            font-size: 13.5px;
            font-weight: 600;
            letter-spacing: -0.2px;
            color: var(--text-1);
        }}
        .sec-caption {{
            font-size: 11.5px;
            color: var(--text-3);
        }}

        /* Active Connection Card */
        .active-connection-card {{
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 12px 16px;
            background: rgba(52, 199, 89, 0.06);
            border: 1px solid rgba(52, 199, 89, 0.18);
            border-radius: 12px;
            margin-bottom: 14px;
        }}
        .conn-idle {{
            background: rgba(0, 0, 0, 0.03);
            border-color: var(--border);
        }}
        @media (prefers-color-scheme: dark) {{
            .conn-idle {{
                background: rgba(255, 255, 255, 0.03);
                border-color: var(--border-sub);
            }}
        }}
        .conn-icon-wrap {{
            width: 28px;
            height: 28px;
            border-radius: 50%;
            background: rgba(52, 199, 89, 0.15);
            color: var(--apple-green);
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
        }}
        .conn-icon-wrap.idle {{
            background: rgba(0, 0, 0, 0.06);
            color: var(--text-3);
        }}
        .conn-text {{
            display: flex;
            flex-direction: column;
            gap: 1px;
            flex: 1;
        }}
        .conn-title {{
            font-size: 12.5px;
            color: var(--text-1);
        }}
        .conn-spec {{
            font-size: 11.5px;
            color: var(--text-3);
        }}
        .conn-badge {{
            display: inline-flex;
            align-items: center;
            gap: 5px;
            font-size: 11.5px;
            color: var(--apple-green);
            font-weight: 500;
        }}
        .badge-idle {{
            color: var(--text-3);
        }}

        /* Power Flow 3-Cards Grid */
        .flow-grid {{
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 12px;
            margin-bottom: 14px;
        }}
        @media (max-width: 600px) {{
            .flow-grid {{ grid-template-columns: 1fr; }}
        }}
        .flow-card {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 16px 18px;
            display: flex;
            flex-direction: column;
            gap: 3px;
            box-shadow: var(--card-shadow);
        }}
        .fl-label {{
            font-size: 11.5px;
            color: var(--text-3);
            font-weight: 500;
        }}
        .fl-val-row {{
            display: flex;
            align-items: baseline;
            gap: 3px;
        }}
        .fl-val {{
            font-size: 24px;
            font-weight: 700;
            letter-spacing: -0.6px;
            color: var(--text-1);
            font-variant-numeric: tabular-nums;
        }}
        .fl-unit {{
            font-size: 14px;
            font-weight: 500;
            color: var(--text-3);
        }}
        .fl-sub {{
            font-size: 11px;
            color: var(--text-3);
        }}

        /* Power Split Meter */
        .flow-meter-container {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 14px 18px;
            margin-bottom: 16px;
            box-shadow: var(--card-shadow);
        }}
        .flow-meter-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 11.5px;
            color: var(--text-3);
            margin-bottom: 8px;
        }}
        .flow-meter-legend {{
            display: flex;
            align-items: center;
            gap: 12px;
        }}
        .leg-item {{
            display: inline-flex;
            align-items: center;
            gap: 5px;
        }}
        .leg-dot {{
            width: 6px;
            height: 6px;
            border-radius: 50%;
        }}
        .dot-sys {{ background: var(--apple-blue); }}
        .dot-bat {{ background: var(--apple-green); }}

        .flow-meter-bar {{
            height: 7px;
            background: rgba(0, 0, 0, 0.05);
            border-radius: 100px;
            display: flex;
            overflow: hidden;
            gap: 2px;
        }}
        @media (prefers-color-scheme: dark) {{
            .flow-meter-bar {{ background: rgba(255, 255, 255, 0.08); }}
        }}
        .flow-seg-sys {{
            background: var(--apple-blue);
            height: 100%;
            border-radius: 100px 0 0 100px;
        }}
        .flow-seg-bat {{
            background: var(--apple-green);
            height: 100%;
            border-radius: 0 100px 100px 0;
        }}
        .power-warning {{
            background: rgba(255, 59, 48, 0.08);
            border: 1px solid rgba(255, 59, 48, 0.2);
            border-radius: 12px;
            padding: 12px 16px;
            color: var(--apple-red);
            font-size: 12px;
            line-height: 1.45;
            margin-bottom: 16px;
        }}

        /* Visual Hardware Port Schematic (Apple Chassis Aesthetic) */
        .hardware-schematic {{
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 16px;
        }}
        @media (max-width: 680px) {{
            .hardware-schematic {{ grid-template-columns: 1fr; }}
        }}
        .chassis-panel {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 18px 20px;
            box-shadow: var(--card-shadow);
        }}
        .chassis-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding-bottom: 12px;
            margin-bottom: 12px;
            border-bottom: 1px solid var(--border-sub);
        }}
        .chassis-title {{
            font-size: 12.5px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .chassis-badge {{
            font-size: 11px;
            padding: 2px 7px;
            border-radius: 100px;
            background: var(--surface-sub);
            color: var(--text-3);
            font-weight: 500;
        }}
        .port-list {{
            display: flex;
            flex-direction: column;
            gap: 8px;
        }}
        .port-chip {{
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 10px 12px;
            border-radius: 10px;
            background: var(--surface-sub);
            border: 1px solid var(--border-sub);
            transition: all 0.15s ease;
        }}
        .port-chip:hover {{
            background: rgba(0, 0, 0, 0.03);
            border-color: rgba(0, 0, 0, 0.1);
        }}
        @media (prefers-color-scheme: dark) {{
            .port-chip:hover {{
                background: rgba(255, 255, 255, 0.04);
                border-color: rgba(255, 255, 255, 0.1);
            }}
        }}
        .port-chip-active {{
            background: rgba(52, 199, 89, 0.06) !important;
            border-color: var(--apple-green) !important;
        }}
        .port-symbol {{
            width: 30px;
            height: 30px;
            border-radius: 8px;
            background: var(--surface);
            border: 1px solid var(--border-sub);
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            color: var(--text-2);
        }}
        .port-chip-active .port-symbol {{
            background: var(--apple-green);
            color: #ffffff;
            border-color: transparent;
            box-shadow: 0 0 10px rgba(52, 199, 89, 0.4);
        }}
        .port-chip-info {{
            display: flex;
            flex-direction: column;
            gap: 1px;
            flex: 1;
        }}
        .port-chip-title-row {{
            display: flex;
            justify-content: space-between;
            align-items: center;
        }}
        .port-chip-name {{
            font-size: 12px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .port-chip-badge {{
            font-size: 10px;
            font-weight: 500;
            color: var(--apple-green);
        }}
        .port-chip-spec {{
            font-size: 11px;
            color: var(--text-3);
        }}

        /* App Table */
        .table-card {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 16px;
            overflow: hidden;
            box-shadow: var(--card-shadow);
        }}
        .app-table {{
            width: 100%;
            border-collapse: collapse;
            font-size: 12px;
        }}
        .app-table th {{
            text-align: left;
            padding: 10px 14px;
            font-size: 11px;
            color: var(--text-3);
            border-bottom: 1px solid var(--border);
            font-weight: 500;
            background: var(--surface-sub);
        }}
        .app-table td {{
            padding: 10px 14px;
            border-bottom: 1px solid var(--border-sub);
            vertical-align: middle;
        }}
        .app-table tr:last-child td {{
            border-bottom: none;
        }}
        .app-table tr:hover td {{
            background: rgba(0, 0, 0, 0.015);
        }}
        .td-app {{
            display: flex;
            align-items: center;
            gap: 10px;
            width: 36%;
        }}
        .app-icon-badge {{
            width: 24px;
            height: 24px;
            border-radius: 6px;
            background: var(--surface-sub);
            border: 1px solid var(--border-sub);
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 10.5px;
            font-weight: 600;
            color: var(--text-2);
            flex-shrink: 0;
        }}
        .app-meta {{
            display: flex;
            flex-direction: column;
            gap: 0;
            overflow: hidden;
        }}
        .app-title {{
            font-weight: 600;
            color: var(--text-1);
            text-overflow: ellipsis;
            overflow: hidden;
            white-space: nowrap;
        }}
        .app-type {{
            font-size: 10.5px;
            color: var(--text-3);
        }}
        .td-mono {{
            color: var(--text-2);
            text-align: right;
            font-variant-numeric: tabular-nums;
        }}
        .td-proc {{
            color: var(--text-3);
        }}
        .td-status {{
            text-align: center;
            width: 60px;
        }}
        .status-badge {{
            display: inline-block;
            padding: 2px 7px;
            border-radius: 5px;
            font-size: 10.5px;
            font-weight: 500;
        }}
        .badge-low {{
            background: rgba(52, 199, 89, 0.12);
            color: #248a3d;
        }}
        .badge-mid {{
            background: rgba(255, 149, 0, 0.12);
            color: #c96d00;
        }}
        .badge-high {{
            background: rgba(255, 59, 48, 0.12);
            color: #d70015;
        }}
        @media (prefers-color-scheme: dark) {{
            .badge-low {{ color: #30D158; }}
            .badge-mid {{ color: #FF9F0A; }}
            .badge-high {{ color: #FF453A; }}
        }}
        .td-meter {{
            width: 90px;
        }}
        .meter-track {{
            width: 100%;
            height: 4px;
            background: rgba(0, 0, 0, 0.05);
            border-radius: 100px;
            overflow: hidden;
        }}
        @media (prefers-color-scheme: dark) {{
            .meter-track {{ background: rgba(255, 255, 255, 0.08); }}
        }}
        .meter-fill {{
            height: 100%;
            background: var(--apple-green);
            border-radius: 100px;
        }}

        /* Timeline Card */
        .timeline-card {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 18px 22px;
            box-shadow: var(--card-shadow);
        }}
        .tl-row {{
            display: flex;
            align-items: flex-start;
            gap: 14px;
            position: relative;
            padding-bottom: 12px;
        }}
        .tl-row:last-child {{
            padding-bottom: 0;
        }}
        .tl-row:not(:last-child)::after {{
            content: '';
            position: absolute;
            left: 69px;
            top: 13px;
            bottom: -2px;
            width: 1px;
            background: var(--border-sub);
        }}
        .tl-time {{
            font-size: 11px;
            color: var(--text-3);
            width: 58px;
            text-align: right;
            padding-top: 1px;
            font-variant-numeric: tabular-nums;
        }}
        .tl-indicator {{
            width: 15px;
            display: flex;
            justify-content: center;
            padding-top: 4px;
            z-index: 1;
        }}
        .tl-dot {{
            width: 6.5px;
            height: 6.5px;
            border-radius: 50%;
        }}
        .tl-content {{
            display: flex;
            flex-direction: column;
            gap: 1px;
            flex: 1;
        }}
        .tl-title {{
            font-size: 12px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .tl-detail {{
            font-size: 11px;
            color: var(--text-3);
        }}

        /* Footer */
        footer {{
            margin-top: 32px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 11px;
            color: var(--text-3);
            border-top: 1px solid var(--border-sub);
            padding-top: 14px;
        }}
        .footer-brand {{
            display: inline-flex;
            align-items: center;
            gap: 5px;
            font-weight: 500;
        }}
    </style>
</head>
<body>
    <div class="shell">
        <header>
            <div class="header-left">
                <div class="brand-icon-wrap">
                    {dynamic_battery_svg}
                </div>
                <div class="device-info">
                    <div class="device-name-row">
                        <span class="device-name">MacBook Pro 14″</span>
                        <span class="live-pill">
                            <span class="pulse-dot"></span>
                            <span id="live-clock">{data['generated_at']}</span>
                        </span>
                    </div>
                    <span class="device-chip">Apple M1 Pro • Bộ nhớ 16 GB</span>
                </div>
            </div>
            <button class="btn-sync" onclick="location.reload()">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/></svg>
                Làm mới
            </button>
        </header>

        <!-- Primary Status Card -->
        <div class="card-main">
            <div class="main-top">
                <div class="pct-group">
                    <span class="pct-number">{data['percent']}%</span>
                    <div class="status-capsule {status_theme_class}">
                        {status_icon}
                        <span>{data['state_str']}</span>
                    </div>
                </div>
                <div class="eta-group">
                    <span class="eta-label">Dự kiến {eta_title}</span>
                    <span class="eta-val">{data['time_remaining']}</span>
                </div>
            </div>

            <div class="battery-bar-track">
                <div class="battery-bar-fill" style="width: {data['percent']}%;"></div>
            </div>

            <div class="stats-strip">
                <div class="stat-item">
                    <span class="st-label">Onscreen đợt này</span>
                    <span class="st-val" id="session-time">{data['session_screen_time']}</span>
                    <span class="st-sub">Từ lúc mở ({data['session_start_time']})</span>
                </div>
                <div class="stat-item">
                    <span class="st-label">Tổng onscreen hôm nay</span>
                    <span class="st-val" id="total-time">{data['total_screen_time']}</span>
                    <span class="st-sub">Tích lũy cả ngày</span>
                </div>
                <div class="stat-item">
                    <span class="st-label">Công suất máy dùng</span>
                    <span class="st-val">{data['sys_load_w']} <span class="st-unit">W</span></span>
                    <span class="st-sub">{data['voltage']} V • {abs(data['amperage'])} mA</span>
                </div>
                <div class="stat-item">
                    <span class="st-label">Sức khỏe pin (Apple)</span>
                    <span class="st-val">{data['apple_health_pct']}%</span>
                    <span class="st-sub">Đo thô cell: {data['raw_health_pct']}%</span>
                </div>
            </div>
        </div>

        <!-- Section 2: Realtime Power Flow & Charging Delivery -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Phân bổ điện năng & nguồn sạc</span>
                <span class="sec-caption">Giám sát dòng nạp sạc và công suất máy dùng</span>
            </div>

            {power_flow_html}

            <!-- Hardware Port Schematic (Apple Chassis Aesthetic) -->
            <div class="hardware-schematic">
                <!-- Left Edge Panel -->
                <div class="chassis-panel">
                    <div class="chassis-header">
                        <span class="chassis-title">Cạnh trái máy (Từ bản lề ra trước)</span>
                        <span class="chassis-badge">3 cổng tiếp điện</span>
                    </div>
                    <div class="port-list">
                        <div class="port-chip">
                            <div class="port-symbol">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="6" width="18" height="12" rx="6"/><circle cx="8" cy="12" r="1.2" fill="currentColor"/><circle cx="12" cy="12" r="1.2" fill="currentColor"/><circle cx="16" cy="12" r="1.2" fill="currentColor"/></svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">1. Cổng MagSafe 3 (Sát bản lề)</span>
                                </div>
                                <span class="port-chip-spec">Sạc nhanh 96W • Từ tính MagSafe thế hệ 3</span>
                            </div>
                        </div>

                        <div class="port-chip {active_class_left}">
                            <div class="port-symbol">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="4" y="8" width="16" height="8" rx="4"/><path d="M12 4v4m0 8v4"/></svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">2. Cổng Type-C / TB4 (Vị trí giữa)</span>
                                    {active_tag_left}
                                </div>
                                <span class="port-chip-spec">Thunderbolt 4 (40 Gbps) • USB-PD 100W</span>
                            </div>
                        </div>

                        <div class="port-chip">
                            <div class="port-symbol">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="4" y="8" width="16" height="8" rx="4"/><path d="M12 4v4m0 8v4"/></svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">3. Cổng Type-C / TB4 (Phía trước)</span>
                                </div>
                                <span class="port-chip-spec">Thunderbolt 4 (40 Gbps) • USB-PD 100W</span>
                            </div>
                        </div>

                        <div class="port-chip">
                            <div class="port-symbol">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3" fill="currentColor"/></svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">4. Jack âm thanh 3.5mm</span>
                                </div>
                                <span class="port-chip-spec">Tự nhận diện tai nghe trở kháng cao</span>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Right Edge Panel -->
                <div class="chassis-panel">
                    <div class="chassis-header">
                        <span class="chassis-title">Cạnh phải máy (Từ bản lề ra trước)</span>
                        <span class="chassis-badge">1 cổng tiếp điện</span>
                    </div>
                    <div class="port-list">
                        <div class="port-chip">
                            <div class="port-symbol">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 7h16l-2 10H6L4 7z"/></svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">1. Cổng HDMI 2.0 (Sát bản lề)</span>
                                </div>
                                <span class="port-chip-spec">Xuất màn hình 4K 60Hz (Không tiếp điện)</span>
                            </div>
                        </div>

                        <div class="port-chip {active_class_right}">
                            <div class="port-symbol">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="4" y="8" width="16" height="8" rx="4"/><path d="M12 4v4m0 8v4"/></svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">2. Cổng Type-C / TB4 (Ở giữa)</span>
                                </div>
                                <span class="port-chip-spec">Thunderbolt 4 (40 Gbps) • USB-PD 100W</span>
                            </div>
                        </div>

                        <div class="port-chip">
                            <div class="port-symbol">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="5" y="4" width="14" height="16" rx="2"/><path d="M9 4v4h6V4"/></svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">3. Khe cắm thẻ nhớ SDXC (Trước)</span>
                                </div>
                                <span class="port-chip-spec">Chuẩn UHS-II tốc độ cao (Không tiếp điện)</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Section 3: Top Power Consumers -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Ứng dụng tiêu thụ năng lượng</span>
                <span class="sec-caption">Sắp xếp theo mức độ tải CPU và bộ nhớ RAM</span>
            </div>

            <div class="table-card">
                <table class="app-table">
                    <thead>
                        <tr>
                            <th>Ứng dụng</th>
                            <th style="text-align: right;">Tải CPU</th>
                            <th style="text-align: right;">Bộ nhớ RAM</th>
                            <th style="text-align: right;">Số luồng</th>
                            <th style="text-align: center;">Đánh giá</th>
                            <th style="text-align: right;">Mức độ tải</th>
                        </tr>
                    </thead>
                    <tbody>
                        {app_rows}
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Section 4: Recent Timeline -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Nhật ký trạng thái gần đây</span>
                <span class="sec-caption">Lịch sử sự kiện nguồn điện & hoạt động</span>
            </div>

            <div class="timeline-card">
                {timeline_rows}
            </div>
        </div>

        <footer>
            <span class="footer-brand">● BatFlow • Tulie Tech</span>
            <span>Cập nhật gần nhất lúc {data['generated_at']}</span>
        </footer>
    </div>

    <script>
        let sessSec = {data['session_on_sec']};
        let totalSec = {data['total_screen_sec']};

        function formatHMS(sec) {{
            const h = Math.floor(sec / 3600);
            const m = Math.floor((sec % 3600) / 60);
            const s = sec % 60;
            return `${{h}}h : ${{String(m).padStart(2, '0')}}m : ${{String(s).padStart(2, '0')}}s`;
        }}

        setInterval(() => {{
            sessSec += 1;
            totalSec += 1;

            const elSess = document.getElementById('session-time');
            const elTotal = document.getElementById('total-time');
            if (elSess) elSess.innerText = formatHMS(sessSec);
            if (elTotal) elTotal.innerText = formatHMS(totalSec);

            const clockEl = document.getElementById('live-clock');
            if (clockEl) {{
                const now = new Date();
                clockEl.innerText = now.toTimeString().split(' ')[0];
            }}
        }}, 1000);
    </script>
</body>
</html>
"""
    return html_out

def main():
    data = get_battery_and_processes()
    html_content = generate_html(data)
    
    if len(sys.argv) > 1 and sys.argv[1]:
        report_path = sys.argv[1]
    else:
        app_support = os.path.expanduser('~/Library/Application Support/BatFlow')
        os.makedirs(app_support, exist_ok=True)
        report_path = os.path.join(app_support, 'battery_report.html')
    
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write(html_content)

    try:
        with open('/tmp/battery_report.html', 'w', encoding='utf-8') as f:
            f.write(html_content)
    except:
        pass

if __name__ == '__main__':
    main()
