-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_rmii_transceiver.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel) / Gideon Zweijtzer
-- Created      : <2025-02-26>
--
-- Description  : RMII to Stream converter for the AES50 IP Core; Modified for AES50 use-case (mainly renamed naming of IO ports)
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
use ieee.numeric_std.all;


entity aes50_rmii_transceiver is
    port (
        clk50_i : in std_logic;         -- 50 MHz reference clk50_i
        rst_i   : in std_logic;

        rmii_crs_dv_i : in  std_logic;
        rmii_rxd_i    : in  std_logic_vector(1 downto 0);
        rmii_tx_en_o  : out std_logic;
        rmii_txd_o    : out std_logic_vector(1 downto 0);

        -- stream bus alike interface to MAC
        eth_rx_data_o  : out std_logic_vector(7 downto 0);
        eth_rx_sof_o   : out std_logic;
        eth_rx_eof_o   : out std_logic;
        eth_rx_valid_o : out std_logic;

        eth_tx_data_i  : in  std_logic_vector(7 downto 0);
        eth_tx_eof_i   : in  std_logic;
        eth_tx_valid_i : in  std_logic;
        eth_tx_ready_o : out std_logic
        );

end entity;

architecture rtl of aes50_rmii_transceiver is
    type t_state is (idle, preamble, data0, data1, data2, data3, crc, gap);
    signal rx_state : t_state;
    signal tx_state : t_state;

    signal crs_dv      : std_logic;
    signal rxd         : std_logic_vector(1 downto 0);
    signal rx_valid    : std_logic;
    signal rx_first    : std_logic;
    signal rx_end      : std_logic;
    signal rx_shift    : std_logic_vector(7 downto 0) := (others => '0');
    signal bad_carrier : std_logic;

    signal rx_crc_sync : std_logic;
    signal rx_crc_dav  : std_logic;
    signal rx_crc_data : std_logic_vector(3 downto 0) := (others => '0');
    signal rx_crc      : std_logic_vector(31 downto 0);
    signal crc_ok      : std_logic;

    signal tx_count    : natural range 0 to 63;
    signal tx_crc_dav  : std_logic;
    signal tx_crc_sync : std_logic;
    signal tx_crc_data : std_logic_vector(1 downto 0);
    signal tx_crc      : std_logic_vector(31 downto 0);
begin
    p_receive : process(clk50_i)
    begin
        if rising_edge(clk50_i) then
            -- synchronize
            crs_dv         <= rmii_crs_dv_i;
            rxd            <= rmii_rxd_i;
            bad_carrier    <= '0';
            rx_valid       <= '0';
            rx_end         <= '0';
            rx_crc_dav     <= '0';
            eth_rx_valid_o <= '0';

            if rx_valid = '1' or rx_end = '1' then
                eth_rx_eof_o <= rx_end;
                eth_rx_sof_o <= rx_first;
                if rx_end = '1' then
                    eth_rx_data_o <= (others => crc_ok);
                else
                    eth_rx_data_o <= rx_shift;
                end if;
                eth_rx_valid_o <= '1';
                rx_first       <= '0';
            end if;

            case rx_state is
                when idle =>
                    if crs_dv = '1' then
                        if rxd = "01" then
                            rx_state <= preamble;
                        elsif rxd = "10" then
                            bad_carrier <= '1';
                        end if;
                    end if;

                when preamble =>
                    rx_first <= '1';
                    if crs_dv = '0' then
                        rx_state <= idle;
                    else                -- dv = 1
                        if rxd = "11" then
                            rx_state <= data0;
                        elsif rxd = "01" then
                            rx_state <= preamble;
                        else
                            bad_carrier <= '1';
                            rx_state    <= idle;
                        end if;
                    end if;

                when data0 =>           -- crs_dv = CRS
                    rx_shift(1 downto 0) <= rxd;
                    rx_state             <= data1;

                when data1 =>           -- crs_dv = DV
                    rx_shift(3 downto 2) <= rxd;
                    rx_state             <= data2;
                    if crs_dv = '0' then
                        rx_end   <= '1';
                        rx_state <= idle;
                    else
                        rx_crc_dav  <= '1';
                        rx_crc_data <= rxd & rx_shift(1 downto 0);
                    end if;

                when data2 =>           -- crs_dv = CRS
                    rx_shift(5 downto 4) <= rxd;
                    rx_state             <= data3;

                when data3 =>           -- crs_dv = DV
                    rx_shift(7 downto 6) <= rxd;
                    rx_crc_dav           <= '1';
                    rx_crc_data          <= rxd & rx_shift(5 downto 4);
                    rx_state             <= data0;
                    rx_valid             <= '1';

                when others =>
                    null;
            end case;

            if rst_i = '1' then
                eth_rx_sof_o  <= '0';
                eth_rx_eof_o  <= '0';
                eth_rx_data_o <= (others => '0');
                rx_first      <= '0';
                rx_state      <= idle;
            end if;
        end if;
    end process;

    process(rx_state)
    begin
        if (rx_state = preamble) then
            rx_crc_sync <= '1';
        else
            rx_crc_sync <= '0';
        end if;
    end process;

    i_receive_crc : entity work.aes50_crc32
        generic map (
            g_data_width => 4
            )
        port map(
            clk50_i      => clk50_i,
            clock_en_i   => '1',
            sync_i       => rx_crc_sync,
            data_i       => rx_crc_data,
            data_valid_i => rx_crc_dav,
            crc_o        => rx_crc
            );

    process(rx_crc)
    begin
        if (rx_crc = X"2144DF1C") then
            crc_ok <= '1';
        else
            crc_ok <= '0';
        end if;

    end process;

    p_transmit : process(clk50_i)
    begin
        if rising_edge(clk50_i) then
            case tx_state is
                when idle =>
                    rmii_tx_en_o <= '0';
                    rmii_txd_o   <= "00";

                    if eth_tx_valid_i = '1' then
                        tx_state <= preamble;
                        tx_count <= 31;
                    end if;

                when preamble =>
                    rmii_tx_en_o <= '1';
                    if tx_count = 0 then
                        rmii_txd_o <= "11";
                        tx_state   <= data0;
                    else
                        rmii_txd_o <= "01";
                        tx_count   <= tx_count - 1;
                    end if;

                when data0 =>
                    if eth_tx_valid_i = '0' then
                        tx_state     <= idle;
                        rmii_tx_en_o <= '0';
                        rmii_txd_o   <= "00";
                    else
                        rmii_tx_en_o <= '1';
                        rmii_txd_o   <= eth_tx_data_i(1 downto 0);
                        tx_state     <= data1;
                    end if;

                when data1 =>
                    rmii_tx_en_o <= '1';
                    rmii_txd_o   <= eth_tx_data_i(3 downto 2);
                    tx_state     <= data2;

                when data2 =>
                    rmii_tx_en_o <= '1';
                    rmii_txd_o   <= eth_tx_data_i(5 downto 4);
                    tx_state     <= data3;

                when data3 =>
                    tx_count     <= 15;
                    rmii_tx_en_o <= '1';
                    rmii_txd_o   <= eth_tx_data_i(7 downto 6);
                    if eth_tx_eof_i = '1' then
                        tx_state <= crc;
                    else
                        tx_state <= data0;
                    end if;

                when crc =>
                    rmii_tx_en_o <= '1';
                    rmii_txd_o   <= tx_crc(31 - tx_count*2 downto 30 - tx_count*2);
                    if tx_count = 0 then
                        tx_count <= 63;
                        tx_state <= gap;
                    else
                        tx_count <= tx_count - 1;
                    end if;

                when gap =>
                    rmii_tx_en_o <= '0';
                    rmii_txd_o   <= "00";
                    if tx_count = 0 then
                        tx_state <= idle;
                    else
                        tx_count <= tx_count - 1;
                    end if;

                when others =>
                    null;

            end case;

            if rst_i = '1' then
                rmii_tx_en_o <= '0';
                rmii_txd_o   <= "00";
                tx_state     <= idle;
            end if;
        end if;
    end process;


    process(tx_state, eth_tx_data_i)
    begin

        if (tx_state = data3) then
            eth_tx_ready_o <= '1';
        else
            eth_tx_ready_o <= '0';
        end if;

        if (tx_state = preamble) then
            tx_crc_sync <= '1';
        else
            tx_crc_sync <= '0';
        end if;

        if (tx_state = data0) then
            tx_crc_dav  <= '1';
            tx_crc_data <= eth_tx_data_i(1 downto 0);
        elsif (tx_state = data1) then
            tx_crc_dav  <= '1';
            tx_crc_data <= eth_tx_data_i(3 downto 2);
        elsif (tx_state = data2) then
            tx_crc_dav  <= '1';
            tx_crc_data <= eth_tx_data_i(5 downto 4);
        elsif (tx_state = data3) then
            tx_crc_dav  <= '1';
            tx_crc_data <= eth_tx_data_i(7 downto 6);
        else
            tx_crc_dav  <= '0';
            tx_crc_data <= "00";
        end if;

    end process;

    i_transmit_crc : entity work.aes50_crc32
        generic map (
            g_data_width => 2
            )
        port map(
            clk50_i      => clk50_i,
            clock_en_i   => '1',
            sync_i       => tx_crc_sync,
            data_i       => tx_crc_data,
            data_valid_i => tx_crc_dav,
            crc_o        => tx_crc
            );

end architecture;
