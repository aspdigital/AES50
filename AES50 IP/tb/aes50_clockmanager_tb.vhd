-------------------------------------------------------------------------------
-- Title      : Testbench for design "aes50_clockmanager"
-- Project    : 
-------------------------------------------------------------------------------
-- File       : aes50_clockmanager_tb.vhd
-- Author     : Andy Peters  <devel@latke.net>
-- Company    : ASP Digital
-- Created    : 2026-03-07
-- Last update: 2026-03-07
-- Platform   : 
-- Standard   : VHDL'08, Math Packages
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
-- Copyright (c) 2026 ASP Digital
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author  Description
-- 2026-03-07  -        andy	Created
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

-------------------------------------------------------------------------------------------------------------

entity aes50_clockmanager_tb is
    generic (
        TBRST_TIME : time := 666 NS);
end entity aes50_clockmanager_tb;

-------------------------------------------------------------------------------------------------------------

architecture testbench of aes50_clockmanager_tb is

    constant CLKPER100MHZ : time := 10 NS;

    -- signals driven by the test bench.
    signal tbarst : std_logic := '1';   -- async reset
    
    -- component ports
    signal clk100_i                       : std_logic := '1';
    signal rst_i                          : std_logic;
    signal sys_mode_i                     : std_logic_vector(1 downto 0);
    signal fs_mode_i                      : std_logic_vector(1 downto 0);
    signal tdm8_i2s_mode_i                : std_logic;
    signal clk_1024xfs_from_pll_i         : std_logic;
    signal pll_lock_n_i                   : std_logic;
    signal clk_to_pll_o                   : std_logic;
    signal pll_mult_value_o               : integer;
    signal mclk_o                         : std_logic;
    signal wclk_o                         : std_logic;
    signal bclk_o                         : std_logic;
    signal wclk_readback_i                : std_logic;
    signal bclk_readback_i                : std_logic;
    signal aes50_clk_a_rx_i               : std_logic;
    signal aes50_clk_a_tx_o               : std_logic;
    signal aes50_clk_a_tx_en_o            : std_logic;
    signal aes50_clk_b_rx_i               : std_logic;
    signal aes50_clk_b_tx_o               : std_logic;
    signal aes50_clk_b_tx_en_o            : std_logic;
    signal assm_self_generated_o          : std_logic;
    signal assm_remote_o                  : std_logic;
    signal clock_health_good_o            : std_logic;
    signal eth_rx_dv_watchdog_i           : std_logic;
    signal eth_rx_consider_good_o         : std_logic;
    signal wd_aes_clk_timeout_i           : integer range 50 downto 0;
    signal wd_aes_rx_dv_timeout_i         : integer range 20000 downto 0;
    signal mdix_timer_1ms_reference_i     : integer range 100000 downto 0;
    signal aes_clk_ok_counter_reference_i : integer range 1000000 downto 0;
    signal mult_clk625_48k_i              : integer;
    signal mult_clk625_44k1_i             : integer;

begin  -- architecture testbench

    -- async reset, perhaps from a button.
    tbarst <= '1', '0' after TBRST_TIME;

    -- test bench clock.
    -- generate main clock and reset in its domain
    clk100_i <= not clk100_i after CLKPER100MHZ;

    SyncReset: process (clk100_i. tbarst) is
    begin  -- process SyncReset
        if tbarst = '1' then
            rst_i <= '1';
        elsif rising_edge(clk100_i) then
            rst_i <= '0';
        end if;
    end process SyncReset;
    

    -- component instantiation
    DUT: entity work.aes50_clockmanager
        port map (
            clk100_i                       => clk100_i,
            rst_i                          => rst_i,
            sys_mode_i                     => sys_mode_i,
            fs_mode_i                      => fs_mode_i,
            tdm8_i2s_mode_i                => tdm8_i2s_mode_i,
            clk_1024xfs_from_pll_i         => clk_1024xfs_from_pll_i,
            pll_lock_n_i                   => pll_lock_n_i,
            clk_to_pll_o                   => clk_to_pll_o,
            pll_mult_value_o               => pll_mult_value_o,
            mclk_o                         => mclk_o,
            wclk_o                         => wclk_o,
            bclk_o                         => bclk_o,
            wclk_readback_i                => wclk_readback_i,
            bclk_readback_i                => bclk_readback_i,
            aes50_clk_a_rx_i               => aes50_clk_a_rx_i,
            aes50_clk_a_tx_o               => aes50_clk_a_tx_o,
            aes50_clk_a_tx_en_o            => aes50_clk_a_tx_en_o,
            aes50_clk_b_rx_i               => aes50_clk_b_rx_i,
            aes50_clk_b_tx_o               => aes50_clk_b_tx_o,
            aes50_clk_b_tx_en_o            => aes50_clk_b_tx_en_o,
            assm_self_generated_o          => assm_self_generated_o,
            assm_remote_o                  => assm_remote_o,
            clock_health_good_o            => clock_health_good_o,
            eth_rx_dv_watchdog_i           => eth_rx_dv_watchdog_i,
            eth_rx_consider_good_o         => eth_rx_consider_good_o,
            wd_aes_clk_timeout_i           => wd_aes_clk_timeout_i,
            wd_aes_rx_dv_timeout_i         => wd_aes_rx_dv_timeout_i,
            mdix_timer_1ms_reference_i     => mdix_timer_1ms_reference_i,
            aes_clk_ok_counter_reference_i => aes_clk_ok_counter_reference_i,
            mult_clk625_48k_i              => mult_clk625_48k_i,
            mult_clk625_44k1_i             => mult_clk625_44k1_i);


    

end architecture testbench;
