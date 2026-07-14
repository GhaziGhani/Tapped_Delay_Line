$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcRoot = Join-Path $root 'original\src'
$unsimRoot = Join-Path $root 'unsim'
$ghdlRoot = Join-Path $root '.ghdl'
$workLib = Join-Path $ghdlRoot 'work'
$unisimLib = Join-Path $ghdlRoot 'unisim'
$waveFile = Join-Path $root 'tdc_sweep_top_tb.vcd'

New-Item -ItemType Directory -Force -Path $workLib, $unisimLib | Out-Null
Remove-Item -Path (Join-Path $workLib '*') -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $unisimLib '*') -Force -ErrorAction SilentlyContinue
Remove-Item -Path $waveFile -Force -ErrorAction SilentlyContinue

$sourceOrder = @(
    'tdc_hold_reg.vhd',
    'tdc_capture_reg.vhd',
    'tdc_bubble_filter.vhd',
    't2b.vhd',
    'course_counter.vhd',
    'phase_sweep.vhd',
    'sweep_engine_legacy.vhd',
    'stats_collector.vhd',
    'tdc_uart_tx.vhd',
    'pulse_launch_v2.vhd',
    'tdc_channel_pulsed.vhd',
    'tapped_delay_line.vhd',
    'clk_gen.vhd',
    'uart_packetiser.vhd',
    'tdc_sweep_top.vhd'
)

Write-Host 'Analyzing UNISIM compatibility library...'
ghdl -a --std=08 --work=unisim --workdir="$unisimLib" (Join-Path $unsimRoot 'unisim_vcomponents.vhd')

Write-Host 'Analyzing design sources...'
foreach ($file in $sourceOrder) {
    $path = Join-Path $srcRoot $file
    ghdl -a --std=08 --work=work --workdir="$workLib" "-P$unisimLib" $path
}

Write-Host 'Analyzing testbench...'
ghdl -a --std=08 --work=work --workdir="$workLib" "-P$unisimLib" (Join-Path $unsimRoot 'tb_tdc_sweep_top.vhd')

Write-Host 'Elaborating testbench...'
ghdl -e --std=08 --work=work --workdir="$workLib" "-P$unisimLib" tb_tdc_sweep_top

Write-Host 'Running simulation...'
ghdl -r --std=08 --work=work --workdir="$workLib" "-P$unisimLib" tb_tdc_sweep_top --stop-time=10ms --vcd="$waveFile"

Write-Host ''
Write-Host "Waveform written to $waveFile"

