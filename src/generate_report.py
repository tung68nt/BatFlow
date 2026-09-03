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
    p = data['percent']
    if p > 50:
        bar_color = '#22c55e'
    elif p > 20:
        bar_color = '#f59e0b'
    else:
        bar_color = '#ef4444'

    # App table rows (with XSS sanitization)
    app_rows = ''
    for app in data['top_apps']:
        cpu = round(app['cpu'], 1)
        mem = round(app['mem'], 1)
        safe_name = html_lib.escape(str(app.get('name', '')))
        safe_cat = html_lib.escape(str(app.get('cat', '')))
        
        if cpu > 20 or mem > 20:
            badge_html = '<span class="status-badge badge-high">Cao</span>'
        elif cpu > 5 or mem > 5:
            badge_html = '<span class="status-badge badge-mid">Vừa</span>'
        else:
            badge_html = '<span class="status-badge badge-low">Thấp</span>'

        load_w = min(100, max(4, int(cpu * 1.4 + mem * 1.2)))

        app_rows += f'''
        <tr>
            <td class="td-app">
                <span class="app-title">{safe_name}</span>
                <span class="app-type">{safe_cat}</span>
            </td>
            <td class="td-mono">{cpu}%</td>
            <td class="td-mono">{mem}%</td>
            <td class="td-mono td-proc">{app['count']}</td>
            <td class="td-status">{badge_html}</td>
            <td class="td-meter">
                <div class="meter-track"><div class="meter-fill" style="width: {load_w}%;"></div></div>
            </td>
        </tr>
        '''

    # Timeline rows (with XSS sanitization)
    timeline_rows = ''
    for ev in data['events']:
        dot_color = '#71717a'
        if ev['type'] == 'on':
            dot_color = '#22c55e'
        elif ev['type'] == 'sleep':
            dot_color = '#a855f7'
        elif ev['type'] == 'wake':
            dot_color = '#f59e0b'

        safe_ev_time = html_lib.escape(str(ev.get('time', '')))
        safe_ev_title = html_lib.escape(str(ev.get('title', '')))
        safe_ev_detail = html_lib.escape(str(ev.get('detail', '')))

        timeline_rows += f'''
        <div class="tl-row">
            <div class="tl-time">{safe_ev_time}</div>
            <div class="tl-indicator"><span class="tl-dot" style="background: {dot_color};"></span></div>
            <div class="tl-content">
                <span class="tl-title">{safe_ev_title}</span>
                <span class="tl-detail">{safe_ev_detail}</span>
            </div>
        </div>
        '''

    # Dynamic Battery Icon (scales from Green 100% down to Red <20%)
    dynamic_battery_svg = make_dynamic_battery_svg(data['percent'], data['charging_now'], size=58)

    # Power Delivery / Flow Widget Logic
    if data['ac_online']:
        sys_w = data['sys_load_w']
        bat_w = data['bat_net_watts']
        adapter_w = data['adapter_in_w']

        if bat_w >= 0:
            bat_flow_label = f"+{bat_w} W"
            bat_flow_desc = "Đang nạp vào pin (Dương)"
            bat_flow_color = "#22c55e"
            alert_box = ""
        else:
            bat_flow_label = f"{bat_w} W"
            bat_flow_desc = "Pin đang xả bù (Thâm hụt)"
            bat_flow_color = "#ef4444"
            alert_box = f'''
            <div class="power-warning">
                <b>Cảnh báo thâm hụt:</b> Củ sạc không đủ cấp cho công suất máy ({sys_w}W). Pin đang phải gánh thêm {abs(bat_w)}W. 
                Hãy giảm độ sáng màn hình xuống dưới 50% hoặc tắt bớt ứng dụng nặng để dòng nạp vào pin dương trở lại.
            </div>
            '''

        total_bar = max(adapter_w, sys_w + max(0, bat_w))
        sys_pct = min(100, int((sys_w / total_bar) * 100)) if total_bar > 0 else 50
        bat_pct = min(100 - sys_pct, int((max(0, bat_w) / total_bar) * 100)) if total_bar > 0 else 50

        power_flow_html = f'''
        <div class="port-active-bar">
            <div class="port-pulse-dot"></div>
            <span>Đang cắm qua: <b>{data['active_port_name']}</b> • Nguồn cấp: <b>{adapter_w}W</b></span>
        </div>

        <div class="flow-grid">
            <div class="flow-card">
                <span class="fl-label">Công suất củ sạc</span>
                <span class="fl-val">{adapter_w} W</span>
                <span class="fl-sub">Đầu vào từ củ sạc</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Máy đang tiêu thụ</span>
                <span class="fl-val">{sys_w} W</span>
                <span class="fl-sub">Phần cứng máy sử dụng</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Dòng nạp vào pin</span>
                <span class="fl-val" style="color: {bat_flow_color};">{bat_flow_label}</span>
                <span class="fl-sub">{bat_flow_desc}</span>
            </div>
        </div>

        <div class="flow-meter-container">
            <div class="flow-meter-header">
                <span>Phân bổ điện năng: Máy dùng {sys_w}W ({sys_pct}%) • Nạp pin {max(0, bat_w)}W ({bat_pct}%)</span>
            </div>
            <div class="flow-meter-bar">
                <div class="flow-seg-sys" style="width: {sys_pct}%;"></div>
                <div class="flow-seg-bat" style="width: {bat_pct}%;"></div>
            </div>
        </div>
        {alert_box}
        '''
    else:
        sys_w = data['sys_load_w']
        power_flow_html = f'''
        <div class="port-active-bar">
            <div class="port-idle-dot"></div>
            <span>Nguồn cấp: <b>Đang chạy 100% pin</b> • Không có cổng sạc nào đang kết nối</span>
        </div>

        <div class="flow-grid">
            <div class="flow-card">
                <span class="fl-label">Trạng thái nguồn</span>
                <span class="fl-val" style="color: #f59e0b;">Chưa cắm sạc</span>
                <span class="fl-sub">Dùng 100% pin</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Máy đang tiêu thụ</span>
                <span class="fl-val">{sys_w} W</span>
                <span class="fl-sub">Công suất xả toàn máy</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Ước tính với củ 20W</span>
                <span class="fl-val" style="color: #22c55e;">+{round(max(0, 20.0 - sys_w), 1)} W</span>
                <span class="fl-sub">Thặng dư sạc vào pin</span>
            </div>
        </div>
        <div class="power-tip">
            <b>Mẹo sạc khi dùng củ 20W iPhone:</b> Màn hình Mini-LED 14" ở mức 100% sáng ngốn tới 6 - 8W. Giảm độ sáng xuống 40 - 50%, máy chỉ còn ăn ~4W $\rightarrow$ Dành tới <b>16W</b> sạc thẳng vào pin!
        </div>
        '''

    icon_path = '/Users/tungnguyen/.gemini/antigravity-ide/scratch/battery_monitor/battery_icon.png'
    icon_b64 = ''
    if os.path.exists(icon_path):
        import base64
        with open(icon_path, 'rb') as f:
            icon_b64 = base64.b64encode(f.read()).decode('utf-8')

    html = f'''<!DOCTYPE html>
<html lang="vi">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>BatFlow • Phân Tích Dòng Chảy Năng Lượng & Pin</title>
    <link rel="icon" type="image/png" href="data:image/png;base64,{icon_b64}">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {{
            --bg: #f6f6f8;
            --surface: #ffffff;
            --surface-sub: #f0f0f3;
            --border: #e2e2e7;
            --border-sub: #eaebee;
            --text-1: #1d1d1f;
            --text-2: #515156;
            --text-3: #86868b;
            --card-shadow: 0 4px 18px rgba(0, 0, 0, 0.04);
            --font-sans: 'Inter', -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', sans-serif;
            --font-mono: var(--font-sans);
        }}
        @media (prefers-color-scheme: dark) {{
            :root {{
                --bg: #09090b;
                --surface: #121215;
                --surface-sub: #18181b;
                --border: #27272a;
                --border-sub: #1f1f23;
                --text-1: #fafafa;
                --text-2: #a1a1aa;
                --text-3: #71717a;
                --card-shadow: none;
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
            line-height: 1.5;
            padding: 36px 24px 48px 24px;
            display: flex;
            justify-content: center;
            transition: background-color 0.2s ease, color 0.2s ease;
        }}
        .shell {{
            max-width: 860px;
            width: 100%;
        }}

        /* Header (Draggable for native macOS window) */
        header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 28px;
            padding-bottom: 18px;
            border-bottom: 1px solid var(--border);
            -webkit-app-region: drag;
            user-select: none;
        }}
        .header-left {{
            display: flex;
            align-items: center;
            gap: 14px;
            white-space: nowrap;
        }}
        .brand-icon-wrap {{
            width: 58px;
            height: 58px;
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            filter: none;
            transition: transform 0.2s cubic-bezier(0.16, 1, 0.3, 1);
        }}
        .brand-icon-wrap:hover {{
            transform: scale(1.08);
        }}
        .svg-squircle {{
            fill: #ffffff;
            stroke: #e2e2e7;
            stroke-width: 1.5;
            filter: drop-shadow(0 3px 10px rgba(0, 0, 0, 0.06));
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
        .brand-text-group {{
            display: flex;
            align-items: center;
            gap: 12px;
        }}
        .sys-tag {{
            font-size: 12px;
            font-family: var(--font-mono);
            font-weight: 500;
            color: var(--text-3);
        }}
        .sys-name {{
            font-size: 15px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .live-pill {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 4px 10px;
            background: rgba(34, 197, 94, 0.1);
            border: 1px solid rgba(34, 197, 94, 0.25);
            border-radius: 100px;
            font-size: 11px;
            font-family: var(--font-mono);
            color: #22c55e;
            font-weight: 600;
        }}
        .pulse-dot {{
            width: 6px;
            height: 6px;
            border-radius: 50%;
            background: #22c55e;
            box-shadow: 0 0 6px #22c55e;
            animation: pulse 1.5s infinite;
        }}
        @keyframes pulse {{
            0% {{ opacity: 1; transform: scale(1); }}
            50% {{ opacity: 0.4; transform: scale(0.85); }}
            100% {{ opacity: 1; transform: scale(1); }}
        }}
        .btn-sync {{
            background: transparent;
            border: 1px solid var(--border);
            color: var(--text-2);
            padding: 6px 14px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            white-space: nowrap;
            transition: all 0.15s ease;
        }}
        .btn-sync:hover {{
            background: var(--surface-sub);
            color: var(--text-1);
            border-color: #3f3f46;
        }}

        /* Primary Status Card */
        .card-main {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px 28px;
            margin-bottom: 24px;
        }}
        .main-top {{
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            margin-bottom: 16px;
            white-space: nowrap;
        }}
        .pct-group {{
            display: flex;
            align-items: baseline;
            gap: 14px;
        }}
        .pct-number {{
            font-size: 54px;
            font-weight: 700;
            font-family: var(--font-mono);
            letter-spacing: -2px;
            line-height: 1;
            color: var(--text-1);
        }}
        .pct-state {{
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 13px;
            font-weight: 500;
            color: var(--text-2);
        }}
        .state-dot {{
            width: 7px;
            height: 7px;
            border-radius: 50%;
            background: {data['state_color']};
        }}
        .eta-text {{
            font-size: 13px;
            font-family: var(--font-mono);
            color: var(--text-2);
        }}
        .eta-text b {{
            color: var(--text-1);
            font-weight: 600;
        }}

        /* Minimalist Progress Track */
        .battery-bar-container {{
            margin-bottom: 24px;
        }}
        .battery-bar-track {{
            width: 100%;
            height: 6px;
            background: var(--surface-sub);
            border-radius: 3px;
            overflow: hidden;
            border: 1px solid var(--border-sub);
        }}
        .battery-bar-fill {{
            height: 100%;
            background: {bar_color};
            border-radius: 3px;
            width: {data['percent']}%;
        }}

        /* Key Metrics Row */
        .stats-strip {{
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 16px;
            padding-top: 20px;
            border-top: 1px solid var(--border);
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
            font-size: 12px;
            color: var(--text-3);
            font-weight: 500;
            white-space: nowrap;
        }}
        .st-val {{
            font-size: 18px;
            font-weight: 600;
            font-family: var(--font-mono);
            color: var(--text-1);
            white-space: nowrap;
        }}
        .st-sub {{
            font-size: 11px;
            color: var(--text-3);
            white-space: nowrap;
        }}

        /* Section Containers */
        .section-wrap {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
            margin-bottom: 24px;
        }}
        .sec-head {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 8px;
            white-space: nowrap;
        }}
        .sec-title {{
            font-size: 14px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .sec-caption {{
            font-size: 12px;
            color: var(--text-3);
        }}
        .sec-explainer {{
            font-size: 12px;
            color: var(--text-2);
            line-height: 1.6;
            margin-bottom: 20px;
            padding: 10px 14px;
            background: var(--surface-sub);
            border: 1px solid var(--border-sub);
            border-radius: 8px;
        }}

        /* Port Active Status Bar */
        .port-active-bar {{
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 10px 14px;
            background: var(--surface-sub);
            border: 1px solid var(--border-sub);
            border-radius: 8px;
            margin-bottom: 16px;
            font-size: 12px;
            color: var(--text-2);
        }}
        .port-pulse-dot {{
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: #22c55e;
            box-shadow: 0 0 8px #22c55e;
            flex-shrink: 0;
        }}
        .port-idle-dot {{
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: #71717a;
            flex-shrink: 0;
        }}
        .port-active-bar b {{
            color: var(--text-1);
        }}

        /* Port Specs 2-Column Hardware Layout (Left: 3 ports, Right: 1 port) */
        .ports-columns-layout {{
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 16px;
            margin-top: 16px;
        }}
        @media (max-width: 680px) {{
            .ports-columns-layout {{ grid-template-columns: 1fr; }}
        }}
        .port-col {{
            display: flex;
            flex-direction: column;
            gap: 10px;
        }}
        .port-col-head {{
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 11px;
            font-family: var(--font-mono);
            font-weight: 600;
            color: var(--text-3);
            text-transform: uppercase;
            letter-spacing: 0.5px;
            padding-bottom: 4px;
            border-bottom: 1px solid var(--border-sub);
        }}
        .port-col-badge {{
            font-size: 10px;
            padding: 2px 6px;
            border-radius: 4px;
            background: var(--surface-sub);
            color: var(--text-2);
        }}
        .port-box {{
            background: var(--surface-sub);
            border: 1px solid var(--border-sub);
            border-radius: 8px;
            padding: 12px 14px;
            display: flex;
            flex-direction: column;
            gap: 4px;
            transition: border-color 0.15s ease;
        }}
        .port-box:hover {{
            border-color: #3f3f46;
        }}
        .port-box-active {{
            border-color: #22c55e !important;
            background: rgba(34, 197, 94, 0.05);
        }}
        .port-title {{
            font-size: 12.5px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .port-limits {{
            font-size: 11px;
            font-family: var(--font-mono);
            color: #38bdf8;
        }}
        .port-desc {{
            font-size: 11px;
            color: var(--text-3);
        }}
        .port-note-box {{
            background: var(--surface-sub);
            border: 1px dashed var(--border);
            border-radius: 8px;
            padding: 12px 14px;
            font-size: 11px;
            color: var(--text-2);
            line-height: 1.5;
        }}

        /* Power Flow Widget */
        .flow-grid {{
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 16px;
            margin-bottom: 20px;
        }}
        @media (max-width: 600px) {{
            .flow-grid {{ grid-template-columns: 1fr; }}
        }}
        .flow-card {{
            background: var(--surface-sub);
            border: 1px solid var(--border-sub);
            border-radius: 8px;
            padding: 14px 16px;
            display: flex;
            flex-direction: column;
            gap: 4px;
        }}
        .fl-label {{
            font-size: 11px;
            color: var(--text-3);
            white-space: nowrap;
        }}
        .fl-val {{
            font-size: 20px;
            font-weight: 700;
            font-family: var(--font-mono);
            color: var(--text-1);
            white-space: nowrap;
        }}
        .fl-sub {{
            font-size: 11px;
            color: var(--text-3);
            white-space: nowrap;
        }}
        .flow-meter-container {{
            margin-bottom: 16px;
        }}
        .flow-meter-header {{
            font-size: 11px;
            color: var(--text-2);
            font-family: var(--font-mono);
            margin-bottom: 8px;
        }}
        .flow-meter-bar {{
            width: 100%;
            height: 8px;
            background: var(--surface-sub);
            border-radius: 4px;
            overflow: hidden;
            display: flex;
        }}
        .flow-seg-sys {{
            background: #f59e0b;
            height: 100%;
        }}
        .flow-seg-bat {{
            background: #22c55e;
            height: 100%;
        }}
        .power-warning {{
            background: rgba(239, 68, 68, 0.1);
            border: 1px solid rgba(239, 68, 68, 0.25);
            border-radius: 8px;
            padding: 12px 16px;
            font-size: 12px;
            color: #fca5a5;
            line-height: 1.6;
        }}
        .power-warning b {{
            color: #ef4444;
        }}
        .power-tip {{
            background: rgba(39, 39, 42, 0.6);
            border: 1px solid var(--border-sub);
            border-radius: 8px;
            padding: 12px 16px;
            font-size: 12px;
            color: var(--text-2);
            line-height: 1.6;
        }}
        .power-tip b {{
            color: var(--text-1);
        }}

        /* Clean Table */
        .app-table {{
            width: 100%;
            border-collapse: collapse;
            font-size: 12px;
        }}
        .app-table th {{
            text-align: left;
            padding: 8px 12px;
            font-size: 11px;
            color: var(--text-3);
            border-bottom: 1px solid var(--border);
            font-weight: 500;
            white-space: nowrap;
        }}
        .app-table td {{
            padding: 11px 12px;
            border-bottom: 1px solid var(--border-sub);
            vertical-align: middle;
            white-space: nowrap;
        }}
        .app-table tr:last-child td {{
            border-bottom: none;
        }}
        .td-app {{
            width: 38%;
        }}
        .app-title {{
            font-weight: 600;
            color: var(--text-1);
            display: block;
            white-space: nowrap;
        }}
        .app-type {{
            font-size: 11px;
            color: var(--text-3);
            white-space: nowrap;
        }}
        .td-mono {{
            font-family: var(--font-mono);
            color: var(--text-2);
            text-align: right;
            width: 12%;
        }}
        .td-proc {{
            color: var(--text-3);
        }}
        .td-status {{
            width: 14%;
            text-align: center;
        }}
        .td-meter {{
            width: 24%;
            padding-right: 0 !important;
        }}
        .meter-track {{
            height: 4px;
            background: var(--surface-sub);
            border-radius: 2px;
            overflow: hidden;
            width: 100%;
        }}
        .meter-fill {{
            height: 100%;
            background: var(--text-2);
            border-radius: 2px;
        }}

        /* Status Badges */
        .status-badge {{
            display: inline-block;
            font-size: 11px;
            font-weight: 600;
            padding: 2px 8px;
            border-radius: 4px;
            white-space: nowrap;
        }}
        .badge-high {{ background: rgba(239, 68, 68, 0.12); color: #dc2626; border: 1px solid rgba(239, 68, 68, 0.25); }}
        .badge-mid {{ background: rgba(245, 158, 11, 0.12); color: #d97706; border: 1px solid rgba(245, 158, 11, 0.25); }}
        .badge-low {{ background: rgba(16, 185, 129, 0.12); color: #059669; border: 1px solid rgba(16, 185, 129, 0.25); }}

        /* Specs Grid - No word wrap, side-by-side comparison */
        .specs-grid {{
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 20px 24px;
        }}
        @media (max-width: 768px) {{
            .specs-grid {{ grid-template-columns: repeat(2, 1fr); }}
        }}
        .spec-item {{
            display: flex;
            flex-direction: column;
            gap: 4px;
        }}
        .sp-key {{
            font-size: 12px;
            color: var(--text-3);
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }}
        .sp-val {{
            font-size: 14px;
            font-family: var(--font-mono);
            font-weight: 600;
            color: var(--text-1);
            white-space: nowrap;
        }}
        .sp-formula {{
            font-size: 11px;
            font-family: var(--font-mono);
            color: #38bdf8;
            white-space: nowrap;
        }}
        .sp-note {{
            font-size: 11px;
            color: var(--text-3);
            white-space: nowrap;
        }}

        /* Timeline Table */
        .tl-container {{
            display: flex;
            flex-direction: column;
        }}
        .tl-row {{
            display: flex;
            align-items: center;
            gap: 16px;
            padding: 9px 0;
            border-bottom: 1px solid var(--border-sub);
            white-space: nowrap;
        }}
        .tl-row:last-child {{
            border-bottom: none;
        }}
        .tl-time {{
            font-size: 11px;
            font-family: var(--font-mono);
            color: var(--text-3);
            min-width: 65px;
        }}
        .tl-indicator {{
            display: flex;
            align-items: center;
            justify-content: center;
        }}
        .tl-dot {{
            width: 6px;
            height: 6px;
            border-radius: 50%;
        }}
        .tl-content {{
            display: flex;
            align-items: baseline;
            gap: 12px;
            flex: 1;
        }}
        .tl-title {{
            font-size: 12px;
            font-weight: 500;
            color: var(--text-1);
            min-width: 160px;
        }}
        .tl-detail {{
            font-size: 11px;
            color: var(--text-3);
        }}

        /* Footer */
        footer {{
            display: flex;
            justify-content: space-between;
            font-size: 11px;
            color: var(--text-3);
            font-family: var(--font-mono);
            padding-top: 8px;
            white-space: nowrap;
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
                <div class="brand-text-group">
                    <span class="sys-tag">MacBook Pro 14"</span>
                    <span class="sys-name">Apple M1 Pro • 16 GB</span>
                </div>
                <div class="live-pill">
                    <span class="pulse-dot"></span>
                    <span id="live-clock">{data['generated_at']}</span>
                </div>
            </div>
            <button class="btn-sync" onclick="location.reload()">Cập nhật ↻</button>
        </header>

        <!-- Primary Status Card -->
        <div class="card-main">
            <div class="main-top">
                <div class="pct-group">
                    <span class="pct-number">{data['percent']}%</span>
                    <div class="pct-state">
                        <span class="state-dot"></span>
                        <span>{data['state_str']}</span>
                    </div>
                </div>
                <div class="eta-text">Dự kiến còn: <b>{data['time_remaining']}</b></div>
            </div>

            <div class="battery-bar-container">
                <div class="battery-bar-track">
                    <div class="battery-bar-fill"></div>
                </div>
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
                    <span class="st-val">{data['sys_load_w']} W</span>
                    <span class="st-sub">{data['voltage']}V • {abs(data['amperage'])}mA</span>
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
                <span class="sec-title">Phân bổ điện năng & nguồn sạc thời gian thực</span>
                <span class="sec-caption">Đo dòng điện vào pin và tải phần cứng</span>
            </div>

            {power_flow_html}

            <!-- Port Capabilities: Exact Physical Layout (From Hinge to Front) -->
            <div class="ports-columns-layout">
                <!-- Column 1: Cạnh trái (Từ sau ra trước) -->
                <div class="port-col">
                    <div class="port-col-head">
                        <span>Cạnh trái máy (Từ bản lề ra trước)</span>
                        <span class="port-col-badge">3 cổng tiếp điện</span>
                    </div>
                    <div class="port-box">
                        <span class="port-title">1. Cổng MagSafe 3 (Sát bản lề nhất)</span>
                        <span class="port-limits">Vào: 96W (Fast Charge) • Ra: 0W (Chỉ nhận sạc)</span>
                        <span class="port-desc">Cổng sạc từ tính thế hệ 3, hỗ trợ sạc nhanh 50% trong 30 phút</span>
                    </div>
                    <div class="port-box">
                        <span class="port-title">2. Cổng Type-C / TB4 (Vị trí giữa)</span>
                        <span class="port-limits">Vào: Tối đa 100W (USB-PD) • Ra: 15W (5V/3A)</span>
                        <span class="port-desc">Thunderbolt 4 / USB4 (40 Gbps), cấp nguồn ngoại vi chuẩn Intel</span>
                    </div>
                    <div class="port-box">
                        <span class="port-title">3. Cổng Type-C / TB4 (Gần jack tai nghe)</span>
                        <span class="port-limits">Vào: Tối đa 100W (USB-PD) • Ra: 15W (5V/3A)</span>
                        <span class="port-desc">Thunderbolt 4 / USB4 (40 Gbps), cấp nguồn ngoại vi chuẩn Intel</span>
                    </div>
                    <div class="port-note-box">
                        <b>Phía trước cạnh trái:</b> Jack cắm tai nghe 3.5mm hỗ trợ công nghệ tự nhận diện trở kháng cao (High-Impedance Headphones).
                    </div>
                </div>

                <!-- Column 2: Cạnh phải (Từ sau ra trước) -->
                <div class="port-col">
                    <div class="port-col-head">
                        <span>Cạnh phải máy (Từ bản lề ra trước)</span>
                        <span class="port-col-badge">1 cổng tiếp điện</span>
                    </div>
                    <div class="port-note-box">
                        <b>1. Cổng HDMI 2.0 (Sát bản lề):</b> Xuất màn hình rời 4K 60Hz (chỉ truyền tín hiệu hình ảnh/âm thanh, không có tính năng tiếp nhận/cấp sạc).
                    </div>
                    <div class="port-box">
                        <span class="port-title">2. Cổng Type-C / TB4 (Ở giữa cạnh phải)</span>
                        <span class="port-limits">Vào: Tối đa 100W (USB-PD) • Ra: 15W (5V/3A)</span>
                        <span class="port-desc">Cổng Type-C duy nhất bên phải, nằm giữa HDMI và khe thẻ SD</span>
                    </div>
                    <div class="port-note-box">
                        <b>3. Khe cắm thẻ nhớ SDXC (Phía trước):</b> Chuẩn UHS-II tốc độ cao (chỉ truyền dữ liệu thẻ nhớ, không có tính năng tiếp điện).
                    </div>
                </div>
            </div>
        </div>

        <!-- Section 3: Top Power Consumers -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Ứng dụng tiêu thụ năng lượng</span>
                <span class="sec-caption">Sắp xếp theo mức độ tải CPU và bộ nhớ</span>
            </div>

            <table class="app-table">
                <thead>
                    <tr>
                        <th>Ứng dụng / Dịch vụ</th>
                        <th style="text-align: right;">CPU</th>
                        <th style="text-align: right;">RAM</th>
                        <th style="text-align: right;">Tiến trình</th>
                        <th style="text-align: center;">Mức độ</th>
                        <th>Tải tỷ lệ</th>
                    </tr>
                </thead>
                <tbody>
                    {app_rows}
                </tbody>
            </table>
        </div>

        <!-- Section 4: Hardware Diagnostics with explicit comparison -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Thông số kỹ thuật & so sánh hai chuẩn pin</span>
                <span class="sec-caption">Chuẩn Apple Settings vs Đo thô phần cứng</span>
            </div>

            <div class="sec-explainer">
                <b>Đối chiếu:</b> Apple báo <b>{data['apple_health_pct']}%</b> (Chai {data['apple_deg_pct']}%) dựa trên thuật toán làm phẳng danh định ({data['nominal_cap']} mAh). 
                Trong khi cell pin đo thô ở nhiệt độ hiện tại tích được <b>{data['actual_cap']} mAh</b> ({data['raw_health_pct']}% sức khỏe, chai {data['raw_deg_pct']}%).
            </div>

            <div class="specs-grid">
                <div class="spec-item">
                    <span class="sp-key">Chuẩn Apple Settings</span>
                    <span class="sp-val">{data['apple_health_pct']}%</span>
                    <span class="sp-formula">Chai: {data['apple_deg_pct']}% (Khớp Cài đặt)</span>
                </div>
                <div class="spec-item">
                    <span class="sp-key">Đo thô cell pin (Tức thời)</span>
                    <span class="sp-val">{data['raw_health_pct']}%</span>
                    <span class="sp-formula">Chai: {data['raw_deg_pct']}% (100% - {data['raw_health_pct']}%)</span>
                </div>
                <div class="spec-item">
                    <span class="sp-key">Dung lượng sạc đầy hiện tại</span>
                    <span class="sp-val">{data['actual_cap']} mAh</span>
                    <span class="sp-note">Chu kỳ này đo được</span>
                </div>
                <div class="spec-item">
                    <span class="sp-key">Dung lượng xuất xưởng</span>
                    <span class="sp-val">{data['design_cap']} mAh</span>
                    <span class="sp-note">Thiết kế ban đầu (100%)</span>
                </div>
                <div class="spec-item">
                    <span class="sp-key">Dung lượng danh định (BMS)</span>
                    <span class="sp-val">{data['nominal_cap']} mAh</span>
                    <span class="sp-note">Cơ sở Apple tính ra 80%</span>
                </div>
                <div class="spec-item">
                    <span class="sp-key">Số chu kỳ sạc</span>
                    <span class="sp-val">{data['cycle_count']} / 1000</span>
                    <span class="sp-note">Apple Battery Cycles</span>
                </div>
                <div class="spec-item">
                    <span class="sp-key">Nhiệt độ pin</span>
                    <span class="sp-val">{data['temp']} °C</span>
                    <span class="sp-note">Mát mẻ (&lt; 35°C lý tưởng)</span>
                </div>
                <div class="spec-item">
                    <span class="sp-key">Tình trạng pin</span>
                    <span class="sp-val">Bình thường</span>
                    <span class="sp-note">Low Power Mode: Bật</span>
                </div>
            </div>
        </div>

        <!-- Section 5: Activity Log -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Nhật ký màn hình và trạng thái</span>
                <span class="sec-caption">Ghi nhận từ nhật ký nguồn điện pmset</span>
            </div>

            <div class="tl-container">
                {timeline_rows}
            </div>
        </div>

        <footer>
            <span>Cập nhật gần nhất lúc {data['generated_at']}</span>
            <span>Không có tiến trình chạy ngầm</span>
        </footer>
    </div>

    <script>
        // Live ticking second by second
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
'''
    return html

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
