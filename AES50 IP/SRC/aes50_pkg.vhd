-------------------------------------------------------------------------------
-- Title      : Support package for AES50 interface
-- Project    : 
-------------------------------------------------------------------------------
-- File       : aes50_pkg.vhd
-- Author     : Andy Peters  <devel@latke.net>
-- Company    : ASP Digital
-- Created    : 2026-03-17
-- Last update: 2026-03-27
-- Platform   : 
-- Standard   : VHDL'08, Math Packages
-------------------------------------------------------------------------------
-- Description: Various constants and types used in an AES50 interface FPGA.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 ASP Digital
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author  Description
-- 2026-03-17  -        andy    Created
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package aes50_pkg is

    -- System Modes.
    constant SYSMODE_AES_SLAVE_TDM_MASTER  : std_logic_vector(1 downto 0) := "00";
    constant SYSMODE_AES_MASTER_TDM_MASTER : std_logic_vector(1 downto 0) := "01";
    constant SYSMODE_AES_MASTER_TDM_SLAVE  : std_logic_vector(1 downto 0) := "10";

    -- set the sample frequency.
    constant FSMODE_44P1 : std_logic_vector(1 downto 0) := "00";
    constant FSMODE_48 : std_logic_vector(1 downto 0) := "01";
    constant FSMODE_88P2 : std_logic_vector(1 downto 0) := "10";
    constant FSMODE_96 : std_logic_vector(1 downto 0) := "11";

    -- Select TDM or I2S.
    constant TDMI2S_SEL_TDM : std_logic := '0';
    constant TDMI2S_SEL_I2S : std_logic := '1';

    -- possible multiplier values for the CS2100 PLL. Which one is used depends on system mode and sample rate.
    constant PLL_MULT_VALUE_CLKX4  : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(4194304, 32));
    constant PLL_MULT_VALUE_CLKX16 : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(16777216, 32));
    
    --multiplication values which will be programmed to CS2100PLL - the target is, that we'll always have a 1024xfs clock (49.152 MHz for 48k, or 45.1584 MHz for 44k1)

    --Multiply by x4 if we get a 12.288 or 11.2896 MHz clock driven into our TDM interface (sys-mode: tdm-slave & aes-master)
  --  signal mult_clk_x4 : integer := 4194304;

    --Multiply by x16 if we get a 3.072 MHz or 2.8224 MHz signal remotely over the AES-Interface (sys-mode: tdm-master & aes-slave)
    --the multiply by x16 is also used, when our IP just operates in I2S mode and expects an external BCLK of also 3.072/2.8224 MHz
    --signal mult_clk_x16 : integer := 16777216;

    

end package aes50_pkg;



