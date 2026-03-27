-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_clockmanager.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Manages all clocking related stuff of the aes50
--
-- License      : GNU General Public License v3.0 or later (GPL-3.0-or-later)
--
-- This file is part of the AES50 VHDL IP-CORE.
--
-- The AES50 VHDL IP-CORE is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as published
-- by the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- The AES50 VHDL IP-CORE is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <https://www.gnu.org/licenses/>.
-- ===========================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use ieee.numeric_std.all;


--sys-mode description
-- 00                   -> aes-slave, tdm-master
-- 01                   -> aes-master, tdm-master
-- 10 or 11     -> aes-master, tdm-slave

--fs-mode description:
-- 00 -> 44.1k 
-- 01 -> 48k
-- 10 -> 88.2k (not implemented yet)
-- 11 -> 96k (not implemented yet)


--tdm8_i2s_mode_i
-- 0 => TDM8
-- 1 => i2s

--Note: rst_i signal in sync with clk100_i



entity aes50_clockmanager is
    generic (
        -- defaults are based on 100 MHz clock.
        WD_AES_CLK_TIMEOUT           : natural := 50;
        WD_AES_RX_DV_TIMEOUT         : natural := 20000;
        MDIX_TIMER_1MS_REFERENCE     : natural := 100000;
        AES_CLK_OK_COUNTER_REFERENCE : natural := 10000000;
        MULT_CLK625_48K              : natural := 8246337;
        MULT_CLK625_44K1             : natural := 7576322);
    port (
        --system clock inputs
        clk100_i : in std_logic;        -- main logic clock
        rst_i    : in std_logic;        -- reset in that domain

        --samplerate and operation mode
        sys_mode_i      : in std_logic_vector(1 downto 0);
        fs_mode_i       : in std_logic_vector(1 downto 0);
        tdm8_i2s_mode_i : in std_logic;

        --interface to external PLL
        clk_1024xfs_from_pll_i : in  std_logic;
        pll_lock_n_i           : in  std_logic;
        clk_to_pll_o           : out std_logic;
        pll_mult_value_o       : out integer;

        --tdm/i2s clk interface
        mclk_o          : out std_logic;
        wclk_o          : out std_logic;
        bclk_o          : out std_logic;
        wclk_readback_i : in  std_logic;
        bclk_readback_i : in  std_logic;


        --connection to clk transceivers
        aes50_clk_a_rx_i    : in  std_logic;
        aes50_clk_a_tx_o    : out std_logic;
        aes50_clk_a_tx_en_o : out std_logic;

        aes50_clk_b_rx_i    : in  std_logic;
        aes50_clk_b_tx_o    : out std_logic;
        aes50_clk_b_tx_en_o : out std_logic;


        --aes frame-sync-marker 
        assm_self_generated_o : out std_logic;  --outputs assm from our self-generated clock
        assm_remote_o         : out std_logic;  --outputs assm from remote-clock

        --clk state output
        clock_health_good_o : out std_logic;

        --aes-input-stream monitoring
        eth_rx_dv_watchdog_i   : in  std_logic;  -- receive data valid
        eth_rx_consider_good_o : out std_logic;


        wd_aes_clk_timeout_i           : in integer range 50 downto 0;       -- 50@100MHz
        wd_aes_rx_dv_timeout_i         : in integer range 20000 downto 0;    -- 15000@100MHz      
        mdix_timer_1ms_reference_i     : in integer range 100000 downto 0;   -- 100000@100MHz
        aes_clk_ok_counter_reference_i : in integer range 1000000 downto 0;  -- 1000000@100MHz
        --Those are the multiplicators needed if we are tdm-master as well as aes-master ->
        --we feed the PLL with a 6.25 MHz clock generated through our 100 MHz clock-domain and multiply to get 49.152 or 45.1584...
        mult_clk625_48k_i              : in integer;                         -- 8246337@100MHz
        mult_clk625_44k1_i             : in integer                          -- 7576322@100MHz

        );
end aes50_clockmanager;

architecture rtl of aes50_clockmanager is


    -- The selected AES clock coming in, based on MDI and presence.
    signal aes_clk_in  : std_logic;
    -- the outgoing AES clock, to A or B based on MDI, and can be either AES clock in or the generated clock.
    signal aes_clk_out : std_logic;

    -- 6.25MHz generator for PLL reference.
    signal clk_625MHz  : std_logic;

    --
    -- Watchdogs
    --
    -- synchronized edges of the incoming AES clocks pet their dogs.
    -- failure to pet indicate that the clock isn't present.
    subtype aes_clk_wd_t is natural range 0 to WD_AES_CLK_TIMEOUT - 1;
    
    signal aes_clk_a_edge_100M : std_logic_vector (2 downto 0);  -- AES CLK A synchronizer
    signal aes_clk_b_edge_100M : std_logic_vector (2 downto 0);  -- AES CLK B synchronizer
    signal wd_aes_clk_a        : aes_clk_wd_t;  -- watchdog timer for AES rx clk A
    signal wd_aes_clk_b        : aes_clk_wd_t;  -- watchdog timer for AES rx clk B
    signal aes_clock_ok        : std_logic;  -- AES RX in clocks and PLL clocks are all good
    
    -- synchronized edge of RMII data-valid flag pets the data-present dog.
    -- when good we assert eth_rx_consider_good_o.
    subtype wd_rx_dv_type is natural range 0 to WD_AES_RX_DV_TIMEOUT - 1;
    signal wd_aes_rx_dv_edge   : std_logic_vector(2 downto 0);   -- RMII DV synchronizer
    signal wd_aes_rx_dv_in     : wd_rx_dv_type;  -- watchdog timer for RMII DV

    --lfsr state machine
    signal lfsr       : std_logic_vector (10 downto 0);
    signal mdix       : std_logic;                      --0 is MDI and 1 is MDI-X
    subtype mdix_timer_t is natural range 0 to MDIX_TIMER_1MS_REFERENCE - 1;
    signal mdix_timer : mdix_timer_t;

    -- initial sync start counter -- hold off everything for 100 ms after clocks are stable per spec.
    subtype aes_100ms_timer_t is natural range 0 to AES_CLK_OK_COUNTER_REFERENCE - 1;
    signal aes_clk_ok_counter : aes_100ms_timer_t;
        
    ---------------------------------------------------------------------------------------------------------
    -- In PLL clock domain.
    --Variables and counters for PLL-clock process

    --aes-clk generator counter
    signal clk_counter     : std_logic_vector (3 downto 0) := "0000";
    signal aes_clk_out_gen : std_logic;

    --self assm generator
    signal aes_sync_counter             : integer range (131072-1) downto 0 := 2;
    signal assm_self_out_signal_counter : integer range 10 downto 0;
    signal assm_self_latch              : std_logic;
    signal assm_self_do                 : integer range 2 downto 0;

    --remote ass, detect
    signal assm_remote_detect_counter     : integer range 100 downto 0;
    signal assm_remote_detect_counter_run : std_logic;
    signal assm_remote_out_signal_counter : integer range 10 downto 0;
    signal aes_clk_in_edge_PLL            : std_logic_vector (2 downto 0);

    --TDM8 / I2S clock generator
    signal tdm8_bclk_mclk_counter : integer range 3 downto 0    := 0;
    signal tdm8_wclk_counter      : integer range 1023 downto 0 := 2;
    signal i2s_bclk_counter       : integer range 15 downto 0   := 0;
    signal i2s_wclk_counter       : integer range 1023 downto 0 := 8;


    -- for sys_mode_i "10" -> wclk-input to aes-clock-sync
    signal wclk_in_edge           : std_logic_vector (2 downto 0);
    signal wclk_to_aes_count_sync : integer range 1023 downto 0 := 1023;

begin

    -- Clock in source select.
    -- by default in MDI (mdix=0), A is TX and B is RX
    -- in MDI-X (mdix=1), A is RX and B is TX
    aes_clk_in <= aes50_clk_b_rx_i when mdix = '0' else aes50_clk_a_rx_i;

    -- clock out depends on system mode.
    -- If this interface is master, our generated clock goes out.
    -- Otherwise, the output follows the selected clock input.
    aes_clk_out      <= aes_clk_in  when (sys_mode_i = SYSMODE_AES_SLAVE_TDM_MASTER) else aes_clk_out_gen;

    -- choose port A or B for clock output depending on MDIX.
    -- reset forces both off.
    aes50_clk_a_tx_o <= aes_clk_out when (mdix = '0' and rst_i = '0') else '0';
    aes50_clk_b_tx_o <= aes_clk_out when (mdix = '1' and rst_i = '0') else '0';

    -- enable the selected port's output drivers.
    aes50_clk_a_tx_en_o <= '1' when (mdix = '0' and rst_i = '0') else '0';
    aes50_clk_b_tx_en_o <= '1' when (mdix = '1' and rst_i = '0') else '0';

    -- Choose the PLL reference clock.
    pll_ref_clk_out_select: process (all) is
    begin  -- process pll_ref_clk_out_select
        enabler: if rst_i = '1' then
            -- force clock to idle  if in reset.
            clk_to_pll_o <= '0';
        else
            selector: case sys_mode_i is
                when SYSMODE_AES_SLAVE_TDM_MASTER =>
                    -- as a slave, the master provides the PLL reference clock.
                    clk_to_pll_o <= aes_clk_in;
                when SYSMODE_AES_MASTER_TDM_MASTER =>
                    -- as a master, and we're also driving TDM as master, the 6.25 MHz clock we generated
                    -- here is the PLL reference clock.
                    clk_to_pll_o <= clk_625MHz;
                when SYSMODE_AES_MASTER_TDM_SLAVE =>
                    -- as a master, and as a TDM slave, we take the bit clock coming in from the TDM interface
                    -- and drive out out as the PLL reference clock.
                    clk_to_pll_o <= bclk_readback_i;
                when others =>
                    -- illegal selection, no clock.
                    clk_to_pll_o <= '0';
            end case selector;
        end if enabler;
        
    end process pll_ref_clk_out_select;

    -- The PLL reference differs in each of the various modes, so we must set the CS2100's multiplier
    -- constant so it synthesizes the correct output frequency.
    pll_mult_select: process (all) is
    begin  -- process pll_mult_select
        sys_mode_select: case sys_mode_i is
            when SYSMODE_AES_SLAVE_TDM_MASTER =>
                
            when others => null;
        end case sys_mode_select;
    end process pll_mult_select;

    pll_mult_value_o <= mult_clk_x16 when (sys_mode_i = "00" or (sys_mode_i = "10" and tdm8_i2s_mode_i = '1')) else
                        mult_clk625_44k1_i when (sys_mode_i = "01" and fs_mode_i = "00") else
                        mult_clk625_48k_i  when (sys_mode_i = "01" and fs_mode_i = "01") else
                        mult_clk_x4;    --sys_mode=10 and tdm8-mode


    ---------------------------------------------------------------------------------------------------------
    -- Generate a 6.25 MHz reference clock for the CS2100.
    ---------------------------------------------------------------------------------------------------------
    GenPllRefClk: process (clk100_i) is
        -- 100 / 6.25 = 16 and toggle every 8
        variable v_clkdiv : natural range 0 to 7;
    begin  -- process GenPllRefClk
        if rising_edge(clk100_i) then
            if rst_i = '0' then
                v_clkdiv := 0;
                clk_625MHz <= '1';
            else
                if v_clkdiv = 0 then
                    v_clkdiv := 7;
                    clk_625MHz <= not clk_625MHz;
                else
                    v_clkdiv := v_clkdiv - 1;
                end if;
            end if;
        end if;
    end process GenPllRefClk;

    ---------------------------------------------------------------------------------------------------------
    -- Watchdog/presence detect for the two incoming AES receive clocks.
    ---------------------------------------------------------------------------------------------------------
    AesClkInWD: process (clk100_i) is
    begin  -- process AesClkInWD
        if rising_edge(clk100_i) then
            if rst_i = '0' then
                aes_clk_a_edge_100M <= (others => '0');  -- AES CLK A synchronizer
                aes_clk_b_edge_100M <= (others => '0');  -- AES CLK B synchronizer
                wd_aes_clk_a        <= 0;                -- watchdog timer for AES rx clk A
                wd_aes_clk_b        <= 0;                -- watchdog timer for AES rx clk B
                aes_clock_ok        <= '0';              -- AES RX in clocks and PLL clocks are all good
                aes_clk_ok_counter  <= 0;                -- both sync ins must be valid for 100 ms before we enable audio
                clock_health_good_o <= '0';              -- true when AES RX clock are valid
            else
                -- synchronizers.
                aes_clk_a_edge_100M <= aes_clk_a_edge_100M(aes_clk_a_edge_100M'LEFT - 1 downto 0) & aes50_clk_a_rx_i;
                aes_clk_b_edge_100M <= aes_clk_b_edge_100M(aes_clk_b_edge_100M'LEFT - 1 downto 0) & aes50_clk_b_rx_i;

                -- rising edge of each input clock pets its dog.
                watchdog_a: if aes_clk_a_edge_100M(2 downto 1) <= "01" then
                    wd_aes_clk_a <= WD_AES_CLK_TIMEOUT - 1;
                else
                    clk_a_timer: if wd_aes_clk_a > 0 then
                        wd_aes_clk_a <= wd_aes_clk_a - 1;
                    end if clk_a_timer;
                end if watchdog_a;

                watchdog_b: if aes_clk_b_edge_100M(2 downto 1) <= "01" then
                    wd_aes_clk_b <= WD_AES_CLK_TIMEOUT - 1;
                else
                    clk_b_timer: if wd_aes_clk_b > 0 then
                        wd_aes_clk_b <= wd_aes_clk_b - 1;
                    end if clk_b_timer;
                end if watchdog_b;

                -- indicate that we have clocks, including from the PLL.
                aes_clock_ok <= '1' when (wd_aes_clk_a > 0) and (wd_aes_clk_b > 0) and (pll_lock_n_i = '0') else '0';

                -- we can enable audio when the sync clocks have been present for the 100 ms indicated in
                -- AES50 spec.
                clocks_good_100ms: if (wd_aes_clk_a > 0) and (wd_aes_clk_b > 0) then
                    -- both clocks are present, so count how long they've been so.
                    -- after 100 ms we declare victory.
                    clocks_good_counter: if aes_clk_ok_counter < AES_CLK_OK_COUNTER_REFERENCE - 1 then
                        aes_clk_ok_counter <= aes_clk_ok_counter + 1;
                    else
                        clock_health_good_o <= '1';
                    end if clocks_good_counter;
                else
                    aes_clk_ok_counter <= 0;
                    clock_health_good_o <= '0';
                end if clocks_good_100ms;
                
            end if;
        end if;
    end process AesClkInWD;

    ---------------------------------------------------------------------------------------------------------
    -- MDI/MDI-X determination, which tells us which clock is in and which is out.
    -- by default in MDI (mdix=0), A is TX and B is RX
    -- in MDI-X (mdix=1), A is RX and B is TX.
    --
    -- A LFSR gives us some randomness to determine which clock port A or B will be transmit or receive. We
    -- start by looking at the head of the LSFR to make the choice. The left-most bit of the LFSR is the
    -- proposed output.
    -- 
    -- A millisecond timer runs continuously. Every millisecond, if we have not already detected sync on a
    -- lock line, we update the LFSR, which then possibly updates our choice of A or B for TX and RX.
    --
    -- We use the time in that millisecond to check for the presence of a clock on A or B which will set
    -- aes_clock_ok, which tells us that we made the correct choice.
    ---------------------------------------------------------------------------------------------------------
    mdi_mdix_select: process (clk100_i) is
    begin  -- process mdi_mdix_select
        if rising_edge(clk100_i) then
            if rst_i = '0' then
                lfsr <= "10110101011";
                mdix_timer <= MDIX_TIMER_1MS_REFERENCE - 1;
                mdix <= '0';
            else
                timer: if mdix_timer = 0 then
                    mdix_timer <= MDIX_TIMER_1MS_REFERENCE - 1;

                    -- possibly update mdix choice if we don't see a clock.
                    no_clock_seen: if aes_clock_ok = '0' then
                        mdxi <= lfsr(lfsr'left);
                    end if no_clock_seen;

                    -- update the shifter every millisecond.
                    -- feedback is z(8) xor z(10)
                    lfsr <= lfsr(9 downto 0) & (lfsr(8) xor lfsr(10));
                else
                    mdix_timer <= mdix_timer - 1;
                end if timer;
            end if;
        end if;
    end process mdi_mdix_select;

    ---------------------------------------------------------------------------------------------------------
    -- Indicate that there are data packets coming in.
    ---------------------------------------------------------------------------------------------------------
    we_have_data: process (clk100_i) is
    begin  -- process we_have_data
        if rising_edge(clk100_i) then
            if rst_i = '0' then      
                wd_aes_rx_dv_edge <= (others => '0');  -- synchronizer
                wd_aes_rx_dv_in <= 0;
            else
                wd_aes_rx_dv_edge <= wd_aes_rx_dv_edge(wd_aes_rx_dv_edge'LEFT - 1 downto 0) & eth_rx_dv_watchdog_i;

                dv_wd: if wd_aes_rx_dv_edge = "01" then
                    wd_aes_rx_dv_in <= WD_AES_RX_DV_TIMEOUT - 1;
                else
                    wd_dv_timer: if wd_aes_rx_dv_in > 0 then
                        wd_aes_rx_dv_in <= wd_aes_rx_dv_in - 1;
                    end if wd_dv_timer;
                end if dv_wd;

                eth_rx_consider_good_o <= '1' when wd_aes_rx_dv_in > 0 else '0';
            end if;
        end if;
    end process we_have_data;



    process (clk_1024xfs_from_pll_i, rst_i)
    begin

        if rst_i = '1' then

            clk_counter                  <= "0000";
            aes_sync_counter             <= 2;
            assm_self_latch              <= '0';
            assm_self_do                 <= 0;
            assm_self_out_signal_counter <= 0;
            wclk_to_aes_count_sync       <= 1023;

        elsif (rising_edge(clk_1024xfs_from_pll_i)) then


            aes_clk_in_edge_PLL <= aes_clk_in_edge_PLL(1 downto 0)&aes_clk_in;

            if (aes_clk_in_edge_PLL(2 downto 1) = "01") then
                assm_remote_detect_counter     <= 0;
                assm_remote_detect_counter_run <= '1';

            elsif (aes_clk_in_edge_PLL(2 downto 1) = "10") then
                if (assm_remote_detect_counter > 8) then
                    --detected
                    assm_remote_out_signal_counter <= 10;
                end if;
                assm_remote_detect_counter_run <= '0';
            else
                if (assm_remote_out_signal_counter > 0) then
                    assm_remote_out_signal_counter <= assm_remote_out_signal_counter - 1;
                    assm_remote_o                  <= '1';
                else
                    assm_remote_o <= '0';
                end if;

                if (assm_remote_detect_counter_run = '1') then
                    assm_remote_detect_counter <= assm_remote_detect_counter + 1;
                end if;

            end if;




            --running continously..

            clk_counter <= std_logic_vector(unsigned(clk_counter) + to_unsigned(1, 4));



            --this aes-sync counter is only needed in case of fs_mode_i 01
            if (clk_counter = "1111") then

                if (tdm8_i2s_mode_i = '0') then
                    wclk_in_edge <= wclk_in_edge(1 downto 0)&wclk_readback_i;
                else
                    --in i2s mode, we need to negate the wclk_readback as left-sample in i2s starts with wclk=low, instead of high-pulse in tdm8
                    wclk_in_edge <= wclk_in_edge(1 downto 0)&(not wclk_readback_i);
                end if;

                --sync one time after reset
                if (sys_mode_i = "10" and wclk_to_aes_count_sync > 0 and wclk_in_edge(2 downto 1) = "01") then
                    aes_sync_counter       <= 0;
                    wclk_to_aes_count_sync <= wclk_to_aes_count_sync - 1;

                else
                    if (aes_sync_counter < 131071) then
                        aes_sync_counter <= aes_sync_counter + 1;
                    else
                        aes_sync_counter <= 0;
                    end if;


                end if;
            end if;



            --aes clock output generator with assm markers      

            --this is the start condition for initiating the assm sync-marker
            if (((sys_mode_i = "01") or (sys_mode_i = "10" and wclk_to_aes_count_sync = 0)) and aes_sync_counter = 0 and clk_counter = "0000") then
                assm_self_out_signal_counter <= 10;

            else
                if (assm_self_out_signal_counter > 0) then
                    assm_self_out_signal_counter <= assm_self_out_signal_counter - 1;
                    assm_self_generated_o        <= '1';
                    assm_self_latch              <= '1';
                else
                    assm_self_generated_o <= '0';

                    if (assm_self_do = 2 and assm_self_latch = '1' and clk_counter = "1111") then
                        assm_self_latch <= '0';
                    end if;

                end if;

            end if;

            --this generates the actual clock
            if (clk_counter = "0000" and assm_self_latch = '1' and assm_self_do = 0) then
                assm_self_do <= 1;
            elsif (clk_counter = "0000" and assm_self_latch = '1' and assm_self_do = 1) then
                assm_self_do <= 2;
            elsif (clk_counter = "1111" and assm_self_do = 2) then
                assm_self_do <= 0;
            end if;

            --do short pulse
            if (assm_self_do = 1) then
                if (unsigned(clk_counter) < to_unsigned(6, 4)) then
                    aes_clk_out_gen <= '1';
                else
                    aes_clk_out_gen <= '0';
                end if;
            --do long pulse     
            elsif (assm_self_do = 2) then
                if (unsigned(clk_counter) < to_unsigned(10, 4)) then
                    aes_clk_out_gen <= '1';
                else
                    aes_clk_out_gen <= '0';
                end if;

            --do normal pulse
            else
                if (unsigned(clk_counter) < to_unsigned(8, 4)) then
                    aes_clk_out_gen <= '1';
                else
                    aes_clk_out_gen <= '0';
                end if;
            end if;




            --this counter always runs, because it's not only the TDM8-BCLK, but also the MCLK which is probably needed for external I2S devices.
            if (tdm8_bclk_mclk_counter < 3) then
                tdm8_bclk_mclk_counter <= tdm8_bclk_mclk_counter + 1;
            else
                tdm8_bclk_mclk_counter <= 0;
            end if;
            if (tdm8_bclk_mclk_counter < 2) then
                mclk_o <= '1';
            else
                mclk_o <= '0';
            end if;


            if (tdm8_i2s_mode_i = '0') then

                --Clock Generator for TDM8 Mode 

                if (tdm8_wclk_counter < 1023) then
                    tdm8_wclk_counter <= tdm8_wclk_counter + 1;
                else
                    tdm8_wclk_counter <= 0;
                end if;

                if (tdm8_wclk_counter < 32) then
                    wclk_o <= '1';
                else
                    wclk_o <= '0';
                end if;

                if (tdm8_bclk_mclk_counter < 2) then
                    bclk_o <= '1';
                else
                    bclk_o <= '0';
                end if;

            else

                --Clock Generator for I2S Mode

                if (i2s_bclk_counter < 15) then
                    i2s_bclk_counter <= i2s_bclk_counter + 1;
                else
                    i2s_bclk_counter <= 0;
                end if;

                if (i2s_wclk_counter < 1023) then
                    i2s_wclk_counter <= i2s_wclk_counter + 1;
                else
                    i2s_wclk_counter <= 0;
                end if;

                if (i2s_wclk_counter < 512) then
                    wclk_o <= '0';
                else
                    wclk_o <= '1';
                end if;

                if (i2s_bclk_counter < 8) then
                    bclk_o <= '1';
                else
                    bclk_o <= '0';
                end if;

            end if;





        end if;

    end process;
end architecture;
