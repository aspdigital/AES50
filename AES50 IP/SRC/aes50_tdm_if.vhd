-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_tdm_if.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Handles TDM-8 Interface (6x TDM8-in, 6x TDM8-out, 1xTDM8-in for aux-data, 1xTDM8-out for aux-data) for the AES50-IP. A reduced I2S alternate-mode is also available.
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
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity aes50_tdm_if is
port (
	clk100_i						: in std_logic;
	rst_i							: in std_logic;
	
	fs_mode_i						: in std_logic_vector(1 downto 0);
	tdm8_i2s_mode_i					: in std_logic;
	
	--tdm if
	tdm_bclk_i						: in std_logic;
	tdm_wclk_i						: in std_logic;
	
	tdm_audio_i						: in std_logic_vector(5 downto 0);
	tdm_audio_o						: out std_logic_vector(5 downto 0);
	
	tdm_aux_i 						: in std_logic;
	tdm_aux_o						: out std_logic;
	
	aes_rx_ok_i 					: in std_logic;
	enable_tx_i						: in std_logic;
	
	--FIFO interface to aes50-tx	
	audio_o							: out std_logic_vector (23 downto 0);
	audio_ch0_marker_o				: out std_logic;
	aux_o							: out std_logic_vector (15 downto 0);
	aux_start_marker_o				: out std_logic;
	audio_out_wr_en_o				: out std_logic;
	aux_out_wr_en_o					: out std_logic;
	
	
	--FIFO interface to aes50-rx
	audio_i							: in std_logic_vector(23 downto 0);
	audio_ch0_marker_i				: in std_logic;
	aux_i							: in std_logic_vector(15 downto 0);
	aux_start_marker_i				: in std_logic;
	audio_in_rd_en_o				: out std_logic;
	aux_in_rd_en_o					: out std_logic;
	fifo_fill_count_audio_i 		: in natural range 0 to 1056 - 1;
	fifo_fill_count_aux_i			: in natural range 0 to 176 - 1;
	
	fifo_misalign_panic_o			: out std_logic;
	
	tdm_debug_o						: out std_logic_vector(3 downto 0)
	
	);
	
end aes50_tdm_if;

architecture rtl of aes50_tdm_if is


	--tdm related serializer signals
	type   tdm48_type is array(0 to 6) of std_logic_vector(191 downto 0); --24*8
	type   tdm8_type  is array(0 to 6) of std_logic_vector(31 downto 0);	
	signal tdm_out_shift							: tdm8_type;
	signal tdm_out_data								: tdm48_type;
	signal tdm_in_shift								: tdm8_type;
	signal tdm_in_data								: tdm48_type;


	--i2s related serializer signals
	signal i2s_out_data_l, i2s_out_data_r			: std_logic_vector(23 downto 0);
	signal i2s_in_shift, i2s_out_shift				: std_logic_vector(31 downto 0);
	signal i2s_in_data_l, i2s_in_data_r				: std_logic_vector(23 downto 0);
	signal i2s_sample_finished						: std_logic;
	signal i2s_sample_finished_size					: natural range 0 to 31;
    signal i2s_sample_in_l_temp 					: std_logic_vector(23 downto 0);
	signal i2s_sample_out_r_temp					: std_logic_vector(23 downto 0);

	
	signal wclk_z									: std_logic;
	signal wclk_zz									: std_logic;	
	signal wclk_old									: std_logic;
	signal wclk_sync_fetch_data						: std_logic;
	signal wclk_sync_store_data						: std_logic;
	signal wclk_sync_fetch_data_shift 				: std_logic_vector (1 downto 0);
	signal wclk_sync_store_data_shift 				: std_logic_vector (1 downto 0);

	signal bclk_shift								: std_logic_vector(2 downto 0);
	signal bclk_counter 							: natural range 0 to 260;

	signal shift_word_in_offset 					: natural range 0 to 8;
	signal shift_word_out_offset 					: natural range 0 to 8;
	signal shift_store_load							: std_logic;

	signal tdm_in_z									: std_logic_vector(5 downto 0);
	signal tdm_in_zz								: std_logic_vector(5 downto 0);
	signal data_in_z								: std_logic;
	signal data_in_zz								: std_logic;
	
	
	--Fifo to Serdes process
	signal state_fifo_reader						: natural range 0 to 15;

	signal sample_serdes_counter_out 				: natural range 0 to 7;
	signal serdes_counter_out						: natural range 0 to 7;
	signal sample_aux_block_counter_out 			: natural range 0 to 15;
	signal aux_counter_out							: natural range 0 to 127;

	
	
	--Serdes to FIFO process
	signal state_fifo_writer						: natural range 0 to 15;
	
	signal sample_serdes_counter_in 				: natural range 0 to 7;
	signal serdes_counter_in						: natural range 0 to 7;
	signal tmp_sample								: std_logic_vector(23 downto 0);


	--temporary aux data buffer
	signal  tmp_aux_word							: std_logic_vector(15 downto 0);
	signal  tmp_aux_offset 							: natural range 0 to 127;
	signal  tmp_aux_valid 							: std_logic;
	
	signal 	aux_ram_we								: std_logic;
	signal  aux_ram_di								: std_logic_vector (15 downto 0);
	signal  aux_ram_do								: std_logic_vector (15 downto 0);
	signal  aux_ram_addr							: natural range 0 to 127;


	--debug signals
	signal 
		debug_serdes_to_fifo_toggle, 
		debug_fifo_to_serdes_process, 
		debug_serdes_rising_edge, 
		debug_serdes_falling_edge : std_logic;




begin

tdm_debug_o <= debug_serdes_to_fifo_toggle & debug_fifo_to_serdes_process & debug_serdes_rising_edge & debug_serdes_falling_edge;

process(clk100_i)
begin

	if (rising_edge(clk100_i)) then
	
		wclk_sync_store_data_shift <= wclk_sync_store_data_shift(0) & wclk_sync_store_data;
		
		if (rst_i = '1' or enable_tx_i = '0') then
		
			state_fifo_writer 			<= 0;
			
			sample_serdes_counter_in 	<= 0;
			serdes_counter_in 			<= 0;			
			tmp_sample 					<= (others=>'0');			
			tmp_aux_word 				<= (others=>'0');
			tmp_aux_valid 				<= '0';
			tmp_aux_offset 				<= 0;	
			audio_o 					<= (others=>'0');
			audio_ch0_marker_o 			<= '0';
			aux_o	 					<= (others=>'0');
			aux_start_marker_o 			<= '0';
			audio_out_wr_en_o 			<= '0';
			aux_out_wr_en_o 			<= '0';
			
			aux_ram_we 					<= '0';
			aux_ram_addr 				<= 0;
			aux_ram_di 					<= (others=>'0');
			
			debug_serdes_to_fifo_toggle	<='0';
			
		else
		
			
			audio_out_wr_en_o <= '0';
			aux_out_wr_en_o <= '0';
			aux_ram_we <= '0';
			
			case state_fifo_writer is
				when 0 =>
					--wait until sync happened
					if (wclk_sync_store_data_shift = "10") then				
						
						tmp_aux_word              		<= (others=>'0');
						tmp_aux_valid             		<= '0';
						tmp_aux_offset            		<= 0;
						sample_serdes_counter_in  		<= 0;
						serdes_counter_in         		<= 0;					
						debug_serdes_to_fifo_toggle 	<= '1';
						state_fifo_writer 				<= 1;
					end if;
				
				
					
				--read from in-data register to tmp-sample	
				when 1 =>
					tmp_sample <= tdm_in_data(serdes_counter_in) (((8-sample_serdes_counter_in)*24)-1 downto ((8-sample_serdes_counter_in)*24)-24);
					state_fifo_writer <= 2;
					
				--write to fifo
				when 2 =>				
					if (tdm8_i2s_mode_i = '1') then
						if (serdes_counter_in = 0 and sample_serdes_counter_in = 0) then
							audio_o <= i2s_in_data_l;
						elsif (serdes_counter_in = 0 and sample_serdes_counter_in = 1) then
							audio_o <= i2s_in_data_r;
						else
							audio_o <= (others=>'0');
						end if;
					else
						audio_o <= tmp_sample;
					end if;
					
					
					if (serdes_counter_in = 0 and sample_serdes_counter_in = 0) then
						audio_ch0_marker_o <= '1';
					else
						audio_ch0_marker_o <= '0';
					end if;
					
					audio_out_wr_en_o <= '1';
					state_fifo_writer <= 3;
					
				
				when 3 =>					
					if (sample_serdes_counter_in < 7) then
						
						sample_serdes_counter_in <= sample_serdes_counter_in + 1;					
						state_fifo_writer <= 1;
						
					else
						sample_serdes_counter_in <= 0;
						
						if (serdes_counter_in < 5) then
							serdes_counter_in <= serdes_counter_in + 1;						
							state_fifo_writer <= 1;
						else
							--we're finished, let's care about aux..
							sample_serdes_counter_in <= 0;
							state_fifo_writer <= 4;
						end if;
					end if;
					
					
				--now we care about the aux-data
				when 4 =>					
					tmp_aux_word 		<= tdm_in_data(6)(((8-sample_serdes_counter_in)*24)-1 downto ((8-sample_serdes_counter_in)*24)-16);
					tmp_aux_valid 		<= tdm_in_data(6)(((8-sample_serdes_counter_in)*24)-17);
					tmp_aux_offset 		<= to_integer (unsigned (tdm_in_data(6)(((8-sample_serdes_counter_in)*24)-18 downto ((8-sample_serdes_counter_in)*24)-24)));
					state_fifo_writer 	<= 5;
				
				
				
				when 5 =>
					--let's rebuffer the data in the local storage if data is valid and offset in the allowed range
					if (tmp_aux_valid = '1' and tmp_aux_offset <=87) then
						aux_ram_we 		<= '1';
						aux_ram_di 		<= tmp_aux_word;
						aux_ram_addr 	<= tmp_aux_offset;
					end if;	
				
					state_fifo_writer <= 6;
					
				when 6 =>			
					--in 48k mode we always handle 44 aux-data-words; 44k1 mode we handle 88 aux-words
					if ( (tmp_aux_offset=43 and fs_mode_i="01") or (tmp_aux_offset=87 and fs_mode_i="00")) then
					
						--if we have found the last data-word of an 44pcs or 88pcs aux-frame, we'll continue writing it back to FIFO
						tmp_aux_offset <= 0;
						state_fifo_writer <= 7;
				
					else
						if (sample_serdes_counter_in < 7) then
							sample_serdes_counter_in <= sample_serdes_counter_in + 1;	
							state_fifo_writer <= 4;	
						else
							state_fifo_writer <= 0;
							debug_serdes_to_fifo_toggle<='0';
						end if;
						
					end if;
					
				
				when 7 =>
					aux_ram_addr <= tmp_aux_offset;
					state_fifo_writer <= 8;
					
				when 8 =>
					--stall cycle
					state_fifo_writer <= 9;
				
				
				--now let's iterate over the local aux storage buffer the write it to FIFO
				when 9 =>
					aux_o <= aux_ram_do;
					if (tmp_aux_offset = 0 or tmp_aux_offset = 44) then
						aux_start_marker_o <= '1';
					else
						aux_start_marker_o <= '0';
					end if;
					
					aux_out_wr_en_o <= '1';
					state_fifo_writer <= 10;
				
				when 10 =>
					if ( (fs_mode_i="01" and tmp_aux_offset < 43) or (fs_mode_i="00" and tmp_aux_offset<87) ) then
						tmp_aux_offset <= tmp_aux_offset + 1;
						state_fifo_writer <= 7;
					else
						state_fifo_writer <= 0;
						debug_serdes_to_fifo_toggle<='0';
					end if;
					
				when others => null;
			end case;
		end if;
		
	end if;
	
end process;


process(clk100_i)
begin

	if (rising_edge(clk100_i)) then
		
		wclk_sync_fetch_data_shift <= wclk_sync_fetch_data_shift(0) & wclk_sync_fetch_data;
		
		if (rst_i = '1' or aes_rx_ok_i = '0') then
	
			tdm_out_data 					<= (others=>(others=>'0'));
			i2s_out_data_l 					<= (others=>'0');
			i2s_out_data_r 					<= (others=>'0');
			
			state_fifo_reader 				<= 0;
			
			serdes_counter_out 				<= 0;
			sample_serdes_counter_out 		<= 0;
			sample_aux_block_counter_out 	<= 0;
			aux_counter_out 				<= 0;
			
			audio_in_rd_en_o 				<= '0';
			aux_in_rd_en_o 					<= '0';
			
			fifo_misalign_panic_o 			<= '0';
			
			debug_fifo_to_serdes_process 	<= '0';
			
		else
			
			audio_in_rd_en_o 	<= '0';
			aux_in_rd_en_o 		<= '0';
			
			--let's wait for wclk-sync
			--if we are in 44k1 mode, we wait until we have 528 audio- and 88 aux-samples
			--in 48k mode, we wait until 288 audio- und 44 aux-samples
			case state_fifo_reader is
				when 0 =>
					if (wclk_sync_fetch_data_shift = "10" and
						((fifo_fill_count_audio_i >= 288 and fifo_fill_count_aux_i >= 44  and fs_mode_i = "01") or
						 (fifo_fill_count_audio_i >= 528 and fifo_fill_count_aux_i >= 88  and fs_mode_i = "00"))) then

						--check if FIFO matches with CH0 
						if (audio_ch0_marker_i /= '1' or aux_start_marker_i /= '1') then
						--indicate panic signal -> will lead to system reset -> we don't have anything to do further here
							fifo_misalign_panic_o <= '1';
						end if;
							
						state_fifo_reader            <= 1;
						audio_in_rd_en_o             <= '1';
						
						serdes_counter_out           <= 0;
						sample_serdes_counter_out    <= 0;
						sample_aux_block_counter_out <= 0;
						aux_counter_out              <= 0;
						debug_fifo_to_serdes_process <= '1';
						tdm_out_data                 <= (others=>(others=>'0'));
					end if;
					
				
				
				when 1 =>				
					state_fifo_reader <= 2;
				
				when 2 =>
					
					if (tdm8_i2s_mode_i = '1') then
						if (serdes_counter_out=0 and sample_serdes_counter_out=0) then
							i2s_out_data_l <= audio_i;
						elsif (serdes_counter_out=0 and sample_serdes_counter_out=1) then
							i2s_out_data_r <= audio_i;
						end if;
					else
						tdm_out_data(serdes_counter_out) (((8-sample_serdes_counter_out)*24)-1 downto ((8-sample_serdes_counter_out)*24)-24) <= audio_i;
					end if;
					
					if (sample_serdes_counter_out < 7) then
						--read next sample from fifo
						sample_serdes_counter_out 	<= sample_serdes_counter_out + 1;
						audio_in_rd_en_o 			<= '1';
						state_fifo_reader 			<= 1;
						
					else
						sample_serdes_counter_out <= 0;
						
						if (serdes_counter_out < 5) then
							serdes_counter_out 		<= serdes_counter_out + 1;
							audio_in_rd_en_o 		<= '1';
							state_fifo_reader 		<= 1;
						else
							--we're finished, let's care about aux..
							state_fifo_reader 		<= 3;
						end if;
					end if;
					
					
				when 3 =>				
					aux_in_rd_en_o 				<= '1';				
					sample_serdes_counter_out 	<= 0;
					state_fifo_reader 			<= 4;
				
				when 4 =>				
					state_fifo_reader <= 5;
					
				when 5 =>
					
					tdm_out_data(6)(((8-sample_serdes_counter_out)*24)-1 downto ((8-sample_serdes_counter_out)*24)-24) <= aux_i & "1" & std_logic_vector(to_unsigned(aux_counter_out,7));
					
					aux_counter_out <= aux_counter_out + 1;
					
					--let's process the first 5 rounds in 48k-mode (distribute 40 aux-words over 5 cycles of 8 TDM slots)
					--in 44k1 mode, let's distribute in 10 rounds in sum 80 words over 8 TDM slots
					if ( (fs_mode_i="01" and sample_aux_block_counter_out < 5) or (fs_mode_i="00" and sample_aux_block_counter_out < 10) ) then
					
						if (sample_serdes_counter_out<7) then
							sample_serdes_counter_out 		<= sample_serdes_counter_out + 1;
							aux_in_rd_en_o 					<= '1';
							state_fifo_reader 				<= 4;
						else
							sample_aux_block_counter_out 	<= sample_aux_block_counter_out + 1;
							state_fifo_reader 				<= 6;
						end if;
					
					else
						--if we are in the last round (round 6 in 48k mode), we only have 4 slots left - therefore this special condition here
						--if we are in 44k1 mode, let's fill all 8 slots to make the 88 words in sum full....
						if ( (fs_mode_i = "01" and sample_serdes_counter_out <3) or (fs_mode_i="00" and sample_serdes_counter_out<7) ) then
						
							sample_serdes_counter_out 		<= sample_serdes_counter_out + 1;
							aux_in_rd_en_o 					<= '1';
							state_fifo_reader 				<= 4;
						else
							--jump back to init state
							--if we are complete with everything, let's jump back to init-state....
							state_fifo_reader 				<= 0; 
							debug_fifo_to_serdes_process 	<= '0';
							sample_aux_block_counter_out 	<= 0;
							aux_counter_out 				<= 0;
						end if;
					end if;
					
				
				--if we are in an "inbetween" state where aux-data is still distributed over slots, let's have this intermediate wait-state
				when 6 =>
					if (wclk_sync_fetch_data_shift="10") then
						
						debug_fifo_to_serdes_process 	<= '1';
						state_fifo_reader 				<= 1;
						audio_in_rd_en_o 				<= '1';
						
						serdes_counter_out 				<= 0;
						sample_serdes_counter_out 		<= 0;		
						
						tdm_out_data 					<= (others=>(others=>'0'));			
					end if;
					
				when others => null;		
			end case;
		end if;
		
	end if;
	
end process;



process (clk100_i)
begin
	if rising_edge(clk100_i) then
		case bclk_counter is
			when 1*32 =>
				shift_word_in_offset  <= 8;
				shift_word_out_offset <= 7;
				shift_store_load      <= '1';
			when 2*32 =>
				shift_word_in_offset  <= 7;
				shift_word_out_offset <= 6;
				shift_store_load      <= '1';
			when 3*32 =>
				shift_word_in_offset  <= 6;
				shift_word_out_offset <= 5;
				shift_store_load      <= '1';
			when 4*32 =>
				shift_word_in_offset  <= 5;
				shift_word_out_offset <= 4;
				shift_store_load      <= '1';
			when 5*32 =>
				shift_word_in_offset  <= 4;
				shift_word_out_offset <= 3;
				shift_store_load      <= '1';
			when 6*32 =>
				shift_word_in_offset  <= 3;
				shift_word_out_offset <= 2;
				shift_store_load      <= '1';
			when 7*32 =>
				shift_word_in_offset  <= 2;
				shift_word_out_offset <= 1;
				shift_store_load      <= '1';
			when 8*32 =>
				shift_word_in_offset  <= 1;
				shift_word_out_offset <= 8;
				shift_store_load      <= '1';
			when others =>
				shift_word_in_offset  <= 8;
				shift_word_out_offset <= 8;
				shift_store_load      <= '0';
		end case;
	end if;
end process;

		
process(clk100_i)
begin

	if rising_edge(clk100_i) then
	

		
		if (rst_i='1') then
		
			tdm_audio_o <= (others=>'0');
			
			if (tdm8_i2s_mode_i = '0') then 
				tdm_in_shift(0) <= (others=>'0');
				tdm_in_shift(1) <= (others=>'0');
				tdm_in_shift(2) <= (others=>'0');
				tdm_in_shift(3) <= (others=>'0');
				tdm_in_shift(4) <= (others=>'0');
				tdm_in_shift(5) <= (others=>'0');
				tdm_in_shift(6) <= (others=>'0');
								
				tdm_out_shift(0) <= (others=>'0');
				tdm_out_shift(1) <= (others=>'0');
				tdm_out_shift(2) <= (others=>'0');
				tdm_out_shift(3) <= (others=>'0');
				tdm_out_shift(4) <= (others=>'0');
				tdm_out_shift(5) <= (others=>'0');
				tdm_out_shift(6) <= (others=>'0');
				
				tdm_in_data(0) <= (others=>'0');
				tdm_in_data(1) <= (others=>'0');
				tdm_in_data(2) <= (others=>'0');
				tdm_in_data(3) <= (others=>'0');
				tdm_in_data(4) <= (others=>'0');
				tdm_in_data(5) <= (others=>'0');
				tdm_in_data(6) <= (others=>'0');

			else
				
				i2s_in_shift 	<= (others=>'0');
				i2s_out_shift 	<= (others=>'0');
				i2s_in_data_l 	<= (others=>'0');
				i2s_in_data_r 	<= (others=>'0');
			end if;
			
			bclk_counter 		 		<= 0;
			wclk_sync_store_data 		<= '0';
			wclk_sync_fetch_data 		<= '0';
		else
		
			
			if (tdm8_i2s_mode_i = '0') then
				--clock needs to be inverted because otherwise it looks from external as it would shift on rising-edge. the process with double-ff the BCLK takes too long otherwise for a 12.228 MHz clock
				bclk_shift <= bclk_shift(1 downto 0)&(not tdm_bclk_i);	
			else
				bclk_shift <= bclk_shift(1 downto 0)&tdm_bclk_i;
			end if;
			
			tdm_in_z <= tdm_audio_i;
			tdm_in_zz <= tdm_in_z;
			data_in_z <= tdm_aux_i;
			data_in_zz <= data_in_z;
			wclk_z <= tdm_wclk_i;
			wclk_zz <= wclk_z;
			
			
			--rising edge of bclk detected - we latch the tdm input pins into our in-shift
			if (bclk_shift(2 downto 1)="01") then	
			
				wclk_old <= wclk_zz;
				if (tdm8_i2s_mode_i = '0' and (wclk_old = '0' and wclk_zz = '1')) then
					bclk_counter <= 1;
					debug_serdes_rising_edge <= '1';
					
				elsif (tdm8_i2s_mode_i = '1' and ((wclk_old = '1' and wclk_zz = '0') or  (wclk_old = '0' and wclk_zz = '1'))) then 
					bclk_counter <= 0;
					i2s_sample_finished <= '1';
					i2s_sample_finished_size <= bclk_counter;
					debug_serdes_rising_edge <= '1';
					
				else
					bclk_counter <= bclk_counter + 1;
					debug_serdes_rising_edge <= '0';				
				end if;
				
				if (tdm8_i2s_mode_i = '0') then
					-- shift input
					tdm_in_shift(0) <= tdm_in_shift(0)(30 downto 0) & tdm_in_zz(0);
					tdm_in_shift(1) <= tdm_in_shift(1)(30 downto 0) & tdm_in_zz(1);
					tdm_in_shift(2) <= tdm_in_shift(2)(30 downto 0) & tdm_in_zz(2);
					tdm_in_shift(3) <= tdm_in_shift(3)(30 downto 0) & tdm_in_zz(3);
					tdm_in_shift(4) <= tdm_in_shift(4)(30 downto 0) & tdm_in_zz(4);
					tdm_in_shift(5) <= tdm_in_shift(5)(30 downto 0) & tdm_in_zz(5);
					tdm_in_shift(6) <= tdm_in_shift(6)(30 downto 0) & data_in_zz;
				else
					i2s_in_shift <= i2s_in_shift(30 downto 0) & tdm_in_zz(0);
				end if;
			
			--falling edge of bclk detected - we shift out
			elsif (bclk_shift(2 downto 1)="10") then
				
				
				if (tdm8_i2s_mode_i = '0') then
				
					--tdm shift engines
					
					if (bclk_counter = 256) then
						wclk_sync_store_data <= '1';
					elsif (bclk_counter = 256-32) then
						wclk_sync_fetch_data <= '1';
					else
						wclk_sync_fetch_data <= '0';
						wclk_sync_store_data <= '0';
					end if;
					
					if (shift_store_load = '1') then	
						--reset the shift vectors
						tdm_in_data(0)(24*shift_word_in_offset-1 downto 24*shift_word_in_offset-24) <= tdm_in_shift(0)(31 downto 8);
						tdm_in_data(1)(24*shift_word_in_offset-1 downto 24*shift_word_in_offset-24) <= tdm_in_shift(1)(31 downto 8);
						tdm_in_data(2)(24*shift_word_in_offset-1 downto 24*shift_word_in_offset-24) <= tdm_in_shift(2)(31 downto 8);
						tdm_in_data(3)(24*shift_word_in_offset-1 downto 24*shift_word_in_offset-24) <= tdm_in_shift(3)(31 downto 8);
						tdm_in_data(4)(24*shift_word_in_offset-1 downto 24*shift_word_in_offset-24) <= tdm_in_shift(4)(31 downto 8);
						tdm_in_data(5)(24*shift_word_in_offset-1 downto 24*shift_word_in_offset-24) <= tdm_in_shift(5)(31 downto 8);
						tdm_in_data(6)(24*shift_word_in_offset-1 downto 24*shift_word_in_offset-24) <= tdm_in_shift(6)(31 downto 8);
						--tdm_in_data(0) <= tdm_out_data(0);
						--tdm_in_data(1) <= tdm_out_data(1);
						--tdm_in_data(2) <= tdm_out_data(2);
						--tdm_in_data(3) <= tdm_out_data(3);
						--tdm_in_data(4) <= tdm_out_data(4);
						--tdm_in_data(5) <= tdm_out_data(5);
						--tdm_in_data(6) <= tdm_out_data(6);
						
						tdm_out_shift(0) <= tdm_out_data(0)(24*shift_word_out_offset-2 downto 24*shift_word_out_offset-24) & "000000000";
						tdm_out_shift(1) <= tdm_out_data(1)(24*shift_word_out_offset-2 downto 24*shift_word_out_offset-24) & "000000000";
						tdm_out_shift(2) <= tdm_out_data(2)(24*shift_word_out_offset-2 downto 24*shift_word_out_offset-24) & "000000000";
						tdm_out_shift(3) <= tdm_out_data(3)(24*shift_word_out_offset-2 downto 24*shift_word_out_offset-24) & "000000000";
						tdm_out_shift(4) <= tdm_out_data(4)(24*shift_word_out_offset-2 downto 24*shift_word_out_offset-24) & "000000000";
						tdm_out_shift(5) <= tdm_out_data(5)(24*shift_word_out_offset-2 downto 24*shift_word_out_offset-24) & "000000000";
						tdm_out_shift(6) <= tdm_out_data(6)(24*shift_word_out_offset-2 downto 24*shift_word_out_offset-24) & "000000000";

						
						tdm_audio_o(0) <= tdm_out_data(0)(24*shift_word_out_offset-1);
						tdm_audio_o(1) <= tdm_out_data(1)(24*shift_word_out_offset-1);
						tdm_audio_o(2) <= tdm_out_data(2)(24*shift_word_out_offset-1);
						tdm_audio_o(3) <= tdm_out_data(3)(24*shift_word_out_offset-1);
						tdm_audio_o(4) <= tdm_out_data(4)(24*shift_word_out_offset-1);
						tdm_audio_o(5) <= tdm_out_data(5)(24*shift_word_out_offset-1);			
						tdm_aux_o <= tdm_out_data(6)(24*shift_word_out_offset-1);
						
						
						
						debug_serdes_falling_edge <= '1';		
					else
						--we have a new 32-bit shift-cycle
					
						debug_serdes_falling_edge <= '0';	
						
								
						tdm_audio_o(0) <= tdm_out_shift(0)(31);
						tdm_audio_o(1) <= tdm_out_shift(1)(31);
						tdm_audio_o(2) <= tdm_out_shift(2)(31);
						tdm_audio_o(3) <= tdm_out_shift(3)(31);
						tdm_audio_o(4) <= tdm_out_shift(4)(31);
						tdm_audio_o(5) <= tdm_out_shift(5)(31);				
						tdm_aux_o <=   tdm_out_shift(6)(31);
						
						tdm_out_shift(0) <= tdm_out_shift(0)(30 downto 0) & "0";
						tdm_out_shift(1) <= tdm_out_shift(1)(30 downto 0) & "0";
						tdm_out_shift(2) <= tdm_out_shift(2)(30 downto 0) & "0";
						tdm_out_shift(3) <= tdm_out_shift(3)(30 downto 0) & "0";
						tdm_out_shift(4) <= tdm_out_shift(4)(30 downto 0) & "0";
						tdm_out_shift(5) <= tdm_out_shift(5)(30 downto 0) & "0";
						tdm_out_shift(6) <= tdm_out_shift(6)(30 downto 0) & "0";
									
					
					end if;
					
				else
				
					--I2S shift engines
					wclk_sync_store_data 		<= '0';
					wclk_sync_fetch_data 		<= '0';
			
					if (i2s_sample_finished = '1') then
						i2s_sample_finished <= '0';
						
						if (wclk_zz = '1') then
						
							if (i2s_sample_finished_size=31) then 									
								i2s_sample_in_l_temp <= i2s_in_shift(31 downto 8);						
							else
								i2s_sample_in_l_temp <= (others=>'0');
							end if;
						
							tdm_audio_o(0) <= i2s_sample_out_r_temp(23);
							i2s_out_shift <= i2s_sample_out_r_temp(22 downto 0) & "000000000";
						else 
						
							wclk_sync_store_data 		<= '1';
							wclk_sync_fetch_data 		<= '1';
							
							if (i2s_sample_finished_size=31) then 								
								i2s_in_data_r <= i2s_in_shift(31 downto 8);												
							else
								i2s_in_data_r <= (others=>'0');
							end if;
							i2s_in_data_l <= i2s_sample_in_l_temp;
							
							tdm_audio_o(0) <= i2s_out_data_l(23);
							i2s_out_shift <= i2s_out_data_l(22 downto 0) & "000000000";
							
							i2s_sample_out_r_temp <= i2s_out_data_r;
							
						end if;
							
					else
						tdm_audio_o(0) <= i2s_out_shift(31);
						i2s_out_shift  <= i2s_out_shift(30 downto 0) & "0";
					end if;
				
					
				end if;
			
			end if;
			
		
		end if;
		
	end if;
	
end process;	
	
	

	
tdm_aux_ram : entity work.aes50_dual_port_bram (rtl)
	generic map(
		RAM_WIDTH => 16,
		RAM_DEPTH => 128	
	)
	port map(
		clka_i => clk100_i,
		clkb_i => clk100_i,
		ena_i => '1',
		enb_i => '0',
		wea_i => aux_ram_we,
		web_i => '0',
		addra_i => aux_ram_addr,
		addrb_i => 0,
		da_i => aux_ram_di,
		db_i => (others => '0'),
		da_o => aux_ram_do,
		db_o => open
	);
		


end architecture;
