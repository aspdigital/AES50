-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_rmii_crc32.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel) / Gideon Zweijtzer
-- Created      : <2025-02-26>
--
-- Description  : CRC32 module for RMII transceiver module
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


library ieee;
use ieee.std_logic_1164.all;

entity aes50_crc32 is
    generic (
        g_data_width : natural := 8);
    port (
        clk50_i      : in std_logic;
        clock_en_i   : in std_logic;
        sync_i       : in std_logic;
        data_i       : in std_logic_vector(g_data_width-1 downto 0);
        data_valid_i : in std_logic;

        crc_o : out std_logic_vector(31 downto 0));
end aes50_crc32;

architecture behavioral of aes50_crc32 is
    signal crc_reg   : std_logic_vector(31 downto 0) := (others => '0');
    constant polynom : std_logic_vector(31 downto 0) := X"04C11DB6";

-- crc_o-32 = x32 + x26 + x23 + x22 + x16 + x12 + x11 + x10 + x8 + x7 + x5 + x4 + x2 + x + 1 (used in Ethernet) 
-- 3322 2222 2222 1111 1111 1100 0000 0000
-- 1098 7654 3210 9876 5432 1098 7654 3210
-- 0000 0100 1100 0001 0001 1101 1011 0111    

begin
    process(clk50_i)
        function new_crc(i, p : std_logic_vector; data_i : std_logic) return std_logic_vector is
            variable sh : std_logic_vector(i'range);
            variable d  : std_logic;
        begin
            d  := data_i xor i(i'high);
            sh := i(i'high-1 downto 0) & d;  --'0';
            if d = '1' then
                sh := sh xor p;
            end if;
            return sh;
        end new_crc;

        variable tmp : std_logic_vector(crc_reg'range);
    begin
        if rising_edge(clk50_i) then
            if clock_en_i = '1' then
                if data_valid_i = '1' then
                    if sync_i = '1' then
                        tmp := (others => '1');
                    else
                        tmp := crc_reg;
                    end if;

                    for i in data_i'reverse_range loop  -- LSB first!
                        tmp := new_crc(tmp, polynom, data_i(i));
                    end loop;
                    crc_reg <= tmp;
                elsif sync_i = '1' then
                    crc_reg <= (others => '1');
                end if;
            end if;
        end if;
    end process;

    process(crc_reg)
    begin
        for i in 0 to 31 loop
            crc_o(i) <= not crc_reg(31-i);
        end loop;
    end process;
end behavioral;
