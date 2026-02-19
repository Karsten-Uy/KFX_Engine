	component FlashMemInterface is
		port (
			clk_clk                 : in  std_logic                     := 'X';             -- clk
			flash_csr_address       : in  std_logic_vector(5 downto 0)  := (others => 'X'); -- address
			flash_csr_read          : in  std_logic                     := 'X';             -- read
			flash_csr_readdata      : out std_logic_vector(31 downto 0);                    -- readdata
			flash_csr_write         : in  std_logic                     := 'X';             -- write
			flash_csr_writedata     : in  std_logic_vector(31 downto 0) := (others => 'X'); -- writedata
			flash_csr_waitrequest   : out std_logic;                                        -- waitrequest
			flash_csr_readdatavalid : out std_logic;                                        -- readdatavalid
			flash_mem_write         : in  std_logic                     := 'X';             -- write
			flash_mem_burstcount    : in  std_logic_vector(6 downto 0)  := (others => 'X'); -- burstcount
			flash_mem_waitrequest   : out std_logic;                                        -- waitrequest
			flash_mem_read          : in  std_logic                     := 'X';             -- read
			flash_mem_address       : in  std_logic_vector(22 downto 0) := (others => 'X'); -- address
			flash_mem_writedata     : in  std_logic_vector(31 downto 0) := (others => 'X'); -- writedata
			flash_mem_readdata      : out std_logic_vector(31 downto 0);                    -- readdata
			flash_mem_readdatavalid : out std_logic;                                        -- readdatavalid
			flash_mem_byteenable    : in  std_logic_vector(3 downto 0)  := (others => 'X'); -- byteenable
			reset_reset_n           : in  std_logic                     := 'X'              -- reset_n
		);
	end component FlashMemInterface;

	u0 : component FlashMemInterface
		port map (
			clk_clk                 => CONNECTED_TO_clk_clk,                 --       clk.clk
			flash_csr_address       => CONNECTED_TO_flash_csr_address,       -- flash_csr.address
			flash_csr_read          => CONNECTED_TO_flash_csr_read,          --          .read
			flash_csr_readdata      => CONNECTED_TO_flash_csr_readdata,      --          .readdata
			flash_csr_write         => CONNECTED_TO_flash_csr_write,         --          .write
			flash_csr_writedata     => CONNECTED_TO_flash_csr_writedata,     --          .writedata
			flash_csr_waitrequest   => CONNECTED_TO_flash_csr_waitrequest,   --          .waitrequest
			flash_csr_readdatavalid => CONNECTED_TO_flash_csr_readdatavalid, --          .readdatavalid
			flash_mem_write         => CONNECTED_TO_flash_mem_write,         -- flash_mem.write
			flash_mem_burstcount    => CONNECTED_TO_flash_mem_burstcount,    --          .burstcount
			flash_mem_waitrequest   => CONNECTED_TO_flash_mem_waitrequest,   --          .waitrequest
			flash_mem_read          => CONNECTED_TO_flash_mem_read,          --          .read
			flash_mem_address       => CONNECTED_TO_flash_mem_address,       --          .address
			flash_mem_writedata     => CONNECTED_TO_flash_mem_writedata,     --          .writedata
			flash_mem_readdata      => CONNECTED_TO_flash_mem_readdata,      --          .readdata
			flash_mem_readdatavalid => CONNECTED_TO_flash_mem_readdatavalid, --          .readdatavalid
			flash_mem_byteenable    => CONNECTED_TO_flash_mem_byteenable,    --          .byteenable
			reset_reset_n           => CONNECTED_TO_reset_reset_n            --     reset.reset_n
		);

