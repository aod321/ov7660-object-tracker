-- Read chunks of data from the SRAM and feed it to the vga generator.
-- Copyright Erik Zachrisson erik@zachrisson.info 2014

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.Types.all;
use work.OV76X0Pack.all;

entity VideoController is
  port (
    Clk           : in  bit1;
    RstN          : in  bit1;
    -- SramController i/f
    ReadSram      : out bit1;
    SramAddr      : out word(SramAddrW-1 downto 0);
    SramReqPopped : in  bit1;
    --
    SramData      : in  word(SramDataW-1 downto 0);
    -- Vga Gen i/f
    InView        : in  bit1;
    PixelToDisp   : out word(PixelResW-1 downto 0);
    PixelVal      : out bit1
    );
end entity;

architecture rtl of VideoController is
  type PixBufArray is array (NoBuffers-1 downto 0) of word(SramDataW-1 downto 0);
  type ValPixBufArray is array (NoBuffers-1 downto 0) of word(NoPixelsW-1 downto 0);

  -- Local buffers
  signal WriteBufPtr_N, WriteBufPtr_D : word(NoBuffersW-1 downto 0);
  signal ReadBufPtr_N, ReadBufPtr_D   : word(NoBuffersW-1 downto 0);

  signal Buf_N, Buf_D                 : PixBufArray;
  signal ValPixelCnt_N, ValPixelCnt_D : ValPixBufArray;
  signal WordCnt_N, WordCnt_D         : word(MemWordsPerLineW-1 downto 0);
  signal LineCnt_N, LineCnt_D         : word(FrameHW-1 downto 0);
  signal FrameCnt_N, FrameCnt_D       : word(NoBuffersW-1 downto 0);

  -- Vga generator runs at half frequency of system 25 MHz vs 50 MHz
  constant Penalty            : natural  := 1;
  constant PenaltyW           : positive := bits(Penalty);
  signal WaitCnt_N, WaitCnt_D : word(PenaltyW-1 downto 0);

  signal SramReqPopped_N, SramReqPopped_D : bit1;
  
begin
  SyncRstProc : process (Clk, RstN)
  begin
    if RstN = '0' then
      ValPixelCnt_D   <= (others => (others => '0'));
      WriteBufPtr_D   <= (others => '0');
      ReadBufPtr_D    <= (others => '0');
      --
      WordCnt_D       <= (others => '0');
      LineCnt_D       <= (others => '0');
      FrameCnt_D      <= (others => '0');
      WaitCnt_D       <= (others => '1');
      SramReqPopped_D <= '0';
    elsif rising_edge(Clk) then
      ValPixelCnt_D   <= ValPixelCnt_N;
      ReadBufPtr_D    <= ReadBufPtr_N;
      WriteBufPtr_D   <= WriteBufPtr_N;
      WordCnt_D       <= WordCnt_N;
      LineCnt_D       <= LineCnt_N;
      FrameCnt_D      <= FrameCnt_N;
      WaitCnt_D       <= WaitCnt_N;
      SramReqPopped_D <= SramReqPopped_N;
    end if;
  end process;

  SyncNoRstProc : process (Clk)
  begin
    if rising_edge(Clk) then
      Buf_D           <= Buf_N;
    end if;
  end process;
  
  AsyncProc : process (Buf_D, ValPixelCnt_D, WriteBufPtr_D, ReadBufPtr_D, WordCnt_D, LineCnt_D, InView, SramReqPopped, SramData, FrameCnt_D, WaitCnt_D, SramReqPopped_D)
    variable ReadPtr, WritePtr : integer;
  begin
    SramReqPopped_N <= SramReqPopped;
    Buf_N           <= Buf_D;
    ValPixelCnt_N   <= ValPixelCnt_D;
    ReadBufPtr_N    <= ReadBufPtr_D;
    WriteBufPtr_N   <= WriteBufPtr_D;
    --
    WordCnt_N       <= WordCnt_D;
    LineCnt_N       <= LineCnt_D;
    FrameCnt_N      <= FrameCnt_D;
    --
    ReadPtr         := conv_integer(ReadBufPtr_D);
    WritePtr        := conv_integer(WriteBufPtr_D);
    --
    ReadSram        <= '0';
    SramAddr        <= xt0(FrameCnt_D & LineCnt_D & WordCnt_D, SramAddr'length);
    -- Display black screen if nothing else
    PixelToDisp     <= (others => '0');
    WaitCnt_N       <= WaitCnt_D;
    PixelVal        <= '0';

    if (InView = '1' and ValPixelCnt_D(WritePtr) > 0) then
      PixelToDisp <= ExtractSlice(Buf_D(WritePtr), PixelResW, conv_integer(ValPixelCnt_D(WritePtr))-1);
      if (WaitCnt_D = 0) then
        PixelVal    <= '1';
        WaitCnt_N               <= conv_word(Penalty, PenaltyW);
        ValPixelCnt_N(WritePtr) <= ValPixelCnt_D(WritePtr) - 1;

        if (ValPixelCnt_D(WritePtr) - 1 = 0) then
          WriteBufPtr_N <= WriteBufPtr_D + 1;
          if (WriteBufPtr_D = NoBuffers-1) then
            WriteBufPtr_N <= (others => '0');
          end if;
        end if;
      else
        WaitCnt_N <= WaitCnt_D - 1;
      end if;
    end if;

    -- Fetch more data
    if ValPixelCnt_D(ReadPtr) = 0 then
      ReadSram <= '1';
    end if;

    if (SramReqPopped_D = '1') then
      ReadSram               <= '0';
      Buf_N(ReadPtr)         <= SramData;
      ValPixelCnt_N(ReadPtr) <= conv_word(NoPixels, NoPixelsW);
      -- Swap local buffer
      ReadBufPtr_N           <= ReadBufPtr_D + 1;
      if (ReadBufPtr_D = NoBuffers-1) then
        ReadBufPtr_N <= (others => '0');
      end if;

      WordCnt_N <= WordCnt_D + 1;
      -- Wrap line
      if (WordCnt_D = MemWordsPerLine-1) then
        WordCnt_N <= (others => '0');
        LineCnt_N <= LineCnt_D + 1;

        if LineCnt_D = FrameH-1 then
          LineCnt_N  <= (others => '0');
          FrameCnt_N <= FrameCnt_D + 1;
          if (FrameCnt_D = NoBuffers-1) then
            FrameCnt_N <= (others => '0');
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture rtl;
