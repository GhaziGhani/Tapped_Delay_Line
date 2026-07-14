# TDC Early Completion - Root Cause Analysis

## Problem Identified
The TDC simulation shows ALL_DONE asserting at cycle 5 (30ns) instead of after the full sweep sequence.

## Root Cause Found

### Primary Issue: BOOT State Logic in phase_sweep.vhd

**Location**: `c:\CONNECTED DELAY LINES\src\phase_sweep.vhd`, lines 95-97

**Problematic Code**:
```vhdl
when BOOT =>
    done_r <= '1';    -- ❌ This sets SWEEP_DONE high immediately
    state  <= IDLE;
```

**Explanation**:
1. At power-on, phase_sweep starts in BOOT state
2. Immediately sets `done_r <= '1'` (SWEEP_DONE signal)
3. Sweep engine receives SWEEP_DONE high in S_WAIT_PHASE state
4. Sweep engine starts measurement sequence immediately
5. Since no actual sweep has occurred, this creates abnormal behavior

### Secondary Issue: Missing Initialization Sequence

The system should follow this sequence:
1. **Power-on** → BOOT state (should NOT assert done)
2. **Initialize** → IDLE state (wait for first sweep request)
3. **First Sweep** → Test phase 0 (BOOT should handle this)
4. **Continue** → Normal sweep operation

## Current (Incorrect) Behavior

```
Power-on → BOOT → done_r='1' → SWEEP_DONE high → Sweep engine starts → Immediate completion
```

## Expected (Correct) Behavior

```
Power-on → BOOT → Initialize phase 0 → done_r='1' → Sweep engine starts phase 0 → Normal sweep
```

## The Fix

The BOOT state should only set done_r='1' AFTER properly initializing phase 0, not immediately.

### Option 1: Fix BOOT State (Recommended)
```vhdl
when BOOT =>
    -- Initialize phase 0
    phase_idx <= (others => '0');
    tap_cnt   <= 0;
    settle_cnt <= 0;
    -- Signal ready for first measurement
    done_r <= '1';
    state  <= IDLE;
```

### Option 2: Remove BOOT State
```vhdl
when BOOT =>
    state <= IDLE;  -- Skip BOOT, go directly to IDLE
```

## Impact Analysis

### Current Impact
- ❌ Simulation completes prematurely (30ns)
- ❌ No actual TDC measurements performed
- ❌ No UART data transmission
- ❌ Reset behavior appears broken

### After Fix Impact
- ✅ Proper sweep sequence execution
- ✅ Full 200-phase measurement cycle
- ✅ UART data transmission
- ✅ Realistic simulation timing (~ms range)

## Verification Steps

1. **Apply the fix** to phase_sweep.vhd
2. **Re-run simulation** with existing testbench
3. **Verify timing**: ALL_DONE should assert after ~1-10ms, not 30ns
4. **Check UART**: Should see data transmission
5. **Validate sweep**: Should see 200 phases × 256 tests = 51,200 measurements

## Files to Modify

1. **`c:\CONNECTED DELAY LINES\src\phase_sweep.vhd`**
   - Lines 95-97: Fix BOOT state logic

## Test Strategy

1. **Minimal Fix Test**: Apply Option 1 fix
2. **Regression Test**: Ensure no other functionality broken
3. **Full Simulation**: Run complete sweep to verify timing
4. **Data Validation**: Check UART output for measurement data

## Conclusion

The early completion is caused by improper BOOT state logic in the phase sweep component. The fix is straightforward and should resolve the simulation issues completely.

**Priority**: HIGH - This blocks all TDC functionality verification
**Complexity**: LOW - Simple logic change
**Risk**: LOW - Limited to initialization sequence

---
Root cause analysis completed - Ready to implement fix
