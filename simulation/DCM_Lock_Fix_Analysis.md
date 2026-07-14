# DCM Lock Issue - Root Cause and Fix

## Problem Identified
After fixing the early completion issue, the DCM (Digital Clock Manager) is not locking.

## Root Cause Analysis

### The Deadlock Circuit 🔄

**Location**: `tdc_sweep_top.vhd`, line 294

**Problematic Code**:
```vhdl
rst_sr <= rst_sr(6 downto 0) & (btn_rst or not dcm_locked);
```

**Circular Dependency**:
1. **DCM Reset Path**: `hw_rst` → DCM.RST_IN
2. **DCM Lock Requirement**: DCM needs reset released to achieve lock
3. **System Reset Logic**: `rst` includes `not dcm_locked`
4. **Deadlock**: DCM can't lock while in reset, but reset won't release until DCM locks

### Visual Representation
```
Power-on → hw_rst=1 → DCM.RST=1 → DCM cannot lock
                ↓
           dcm_locked=0 → not dcm_locked=1 → rst=1 → System held in reset
                ↓
           Infinite loop: DCM never gets chance to lock
```

## The Fix Applied

### Strategy: Separate Reset Domains

**Key Insight**: DCM only needs power-on reset, not continuous system reset.

### Changes Made

#### 1. Separate DCM Reset Signal
```vhdl
-- NEW: Separate DCM reset
signal dcm_rst : STD_LOGIC;

-- DCM only needs power-on reset, not button reset
dcm_rst <= por;  -- Only power-on reset
hw_rst <= por or btn_rst;  -- Full hardware reset for other logic
```

#### 2. Fix System Reset Logic
```vhdl
-- OLD (deadlock):
rst_sr <= rst_sr(6 downto 0) & (btn_rst or not dcm_locked);

-- NEW (fixed):
rst_sr <= rst_sr(6 downto 0) & btn_rst;  -- Only button reset
```

#### 3. Update DCM Instantiation
```vhdl
U_CLK_GEN : clk_gen
    port map (
        CLK_50_IN  => clk_in_buf,
        RST_IN     => dcm_rst,  -- Use separate DCM reset
        -- ... other ports
    );
```

## Expected Behavior After Fix

### Power-On Sequence
1. **Power-on**: `por=1`, `dcm_rst=1`, `hw_rst=1`
2. **DCM Reset**: DCM held in reset briefly
3. **Power-on Reset Complete**: `por=0`, `dcm_rst=0`, DCM starts locking
4. **DCM Lock**: `dcm_locked=1` after lock time
5. **System Reset**: Only controlled by `btn_rst` (user input)
6. **Normal Operation**: DCM locked, system ready

### Reset Behavior
- **Power-on reset**: Both DCM and system reset
- **Button reset**: Only system reset (DCM remains locked)
- **DCM lock loss**: No longer affects system reset

## Benefits of the Fix

### 1. Eliminates Deadlock
- ✅ DCM can lock independently
- ✅ System reset doesn't depend on DCM lock
- ✅ Proper power-on sequence

### 2. Improved Robustness
- ✅ DCM lock loss doesn't reset entire system
- ✅ Button reset works without affecting DCM
- ✅ Better separation of concerns

### 3. Simulation Compatibility
- ✅ DCM lock behavior matches hardware
- ✅ No more circular dependencies
- ✅ Predictable reset timing

## Files Modified

### Primary Fix
- **`tdc_sweep_top_fixed.vhd`** - Complete fixed version

### Key Changes
1. **Line 189**: Added `dcm_rst` signal
2. **Line 269**: Separated DCM reset logic
3. **Line 277**: Updated DCM reset connection
4. **Line 294**: Fixed system reset logic

## Testing Strategy

### 1. DCM Lock Verification
- Monitor `LOCKED` signal after power-on
- Verify lock time is reasonable (~ms range)
- Confirm lock is stable

### 2. Reset Functionality
- Test power-on reset sequence
- Verify button reset works independently
- Confirm DCM remains locked during system reset

### 3. Full System Test
- Run complete TDC sweep
- Verify UART data transmission
- Check timing and functionality

## Implementation Steps

1. **Replace** `src/tdc_sweep_top.vhd` with fixed version
2. **Re-run** simulation
3. **Verify** DCM lock behavior
4. **Test** complete TDC functionality

## Expected Results

### Before Fix
- ❌ DCM never locks (LOCKED=0)
- ❌ System stuck in reset
- ❌ No TDC operation

### After Fix
- ✅ DCM locks after power-on (LOCKED=1)
- ✅ System reset works properly
- ✅ Full TDC sweep operation
- ✅ UART data transmission

## Conclusion

The DCM lock issue was caused by a circular dependency in the reset logic. By separating the DCM reset from the system reset, the deadlock is eliminated and proper operation is restored.

**Priority**: CRITICAL - Blocks all TDC functionality
**Complexity**: LOW - Simple logic change
**Risk**: LOW - Improves reset architecture

---
DCM lock fix analysis completed - Ready for implementation
