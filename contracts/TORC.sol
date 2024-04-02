//SPDX-License-Identifier: MIT 

pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';

import "hardhat/console.sol";

contract TORC is ERC20, ERC20Burnable, ERC20Pausable, Ownable, ERC20Capped { 
	// string constant _name = "Torc"; 
	// string constant _symbol = "TORC";
	uint8 constant _decimals = 9;
	uint256 constant _totalSupply = 432_000_000 * 10**_decimals;
	uint256 constant _treasuryAmount = 100_000_000 * 10**_decimals;
	uint256 constant _devFundAmount = 100_000_000 * 10**_decimals;
	uint256 constant _marketingAmount = 100_000_000 * 10**_decimals;
	uint256 constant _liquidityPoolAmount = 100_000_000 * 10**_decimals;
	uint256 constant _teamAmount = 32_000_000 * 10**_decimals;

	address payable private taxWallet;
	address payable public treasuryWallet;
	address payable public marketingWallet;
	address payable public teamWallet;
	address payable public devWallet;
	address payable public uniswapRouterV2Address;

	mapping (address => bool) public excludedFromFees;

	bool public tradingOpen;
	uint256 public taxSwapMin; uint256 public taxSwapMax;
	mapping (address => bool) private _isLiqPool;
	uint8 constant _maxTaxRate = 5; 
	uint8 public taxRateBuy; 
	uint8 public taxRateSell;

	bool public antiBotEnabled;
	mapping (address => bool) public excludedFromAntiBot;
	mapping (address => uint256) private _lastSwapBlock;

	bool private _inTaxSwap = false;
	IUniswapV2Router02 private _uniswapV2Router;
	modifier lockTaxSwap { 
		_inTaxSwap = true; _; 
		_inTaxSwap = false; 
		}

	event TokensAirdropped(uint256 totalWallets, uint256 totalTokens);
	event TokensBurned(address indexed burnedByWallet, uint256 tokenAmount);
	event TaxWalletChanged(address newTaxWallet);
	event TaxRateChanged(uint8 newBuyTax, uint8 newSellTax);

	constructor (address _uniswapV2RouterAddress, address _taxWallet, address _treasuryWallet, address _devWallet, address _marketingWallet, address _teamWallet) ERC20("Torc", "TORC") ERC20Capped(_totalSupply) Ownable(msg.sender) {
		uniswapRouterV2Address = payable(_uniswapV2RouterAddress);
		taxWallet = payable(_taxWallet);
		treasuryWallet = payable(_treasuryWallet);
		devWallet = payable(_devWallet);
		marketingWallet = payable(_marketingWallet);
		teamWallet = payable(_teamWallet);

		taxSwapMin = _totalSupply * 10 / 10000;
		taxSwapMax = _totalSupply * 50 / 10000;
		_uniswapV2Router = IUniswapV2Router02(_uniswapV2RouterAddress);
		excludedFromFees[_uniswapV2RouterAddress] = true; 

		excludedFromAntiBot[msg.sender] = true;
		excludedFromAntiBot[address(this)] = true;

		excludedFromFees[msg.sender] = true;
		excludedFromFees[address(this)] = true;
		excludedFromFees[address(0)] = true;
		excludedFromFees[_taxWallet] = true;
		excludedFromFees[_treasuryWallet] = true;
		excludedFromFees[_devWallet] = true;
		excludedFromFees[_marketingWallet] = true;
		excludedFromFees[_teamWallet] = true;

		taxRateBuy = 3;
		taxRateSell = 3;

	}

	receive() external payable {}

	 function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }
	
	function transfer(address recipient, uint256 amount) public override returns (bool) {
		require(_checkTradingOpen(), "Trading not open");
		super.transfer(recipient, amount);
	}

	function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
		require(_checkTradingOpen(), "Trading not open");
		super.transferFrom(sender, recipient, amount); 
	}

	function _distributeInitialBalances() internal {
		_mint(devWallet, _devFundAmount);
		_mint(treasuryWallet, _treasuryAmount);
		_mint(marketingWallet, _marketingAmount);
		_mint(teamWallet, _teamAmount); 
		_mint(address(this), _liquidityPoolAmount); 
	}

	function distributeInitialBalances() public onlyOwner {
		_distributeInitialBalances();
	}

	function initLP() external onlyOwner {
		require(!tradingOpen, "trading already open");

		uint256 _contractETHBalance = address(this).balance;
		require(_contractETHBalance > 0, "no eth in contract");

		uint256 _contractTokenBalance = balanceOf(address(this));
		require(_contractTokenBalance > 0, "no tokens");
		address _uniLpAddr = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());
		_isLiqPool[_uniLpAddr] = true;

		_approveRouter(_contractTokenBalance);
		_addLiquidity(_contractTokenBalance, _contractETHBalance, false);

		// _openTrading(); //trading will be open manually through enableTrading() function
	}

	function setUniswapRouter(address newRouter) external onlyOwner {
		_uniswapV2Router = IUniswapV2Router02(newRouter);
	}

	function _approveRouter(uint256 _tokenAmount) internal {
		if (allowance(address(this), uniswapRouterV2Address) < _tokenAmount) {			
			approve(uniswapRouterV2Address, type(uint256).max); 
		}
	}

	function _addLiquidity(uint256 _tokenAmount, uint256 _ethAmountWei, bool autoburn) internal {
		address lpTokenRecipient = address(0);
		if (!autoburn) { 
			lpTokenRecipient = owner();  
		}
		_uniswapV2Router.addLiquidityETH {value: _ethAmountWei} (address(this), _tokenAmount, 0, 0, lpTokenRecipient, block.timestamp);
	}

    function enableTrading() external onlyOwner {
        _openTrading();
    }

	function _openTrading() internal {
        require(!tradingOpen, "trading already open");
		tradingOpen = true;
	}

	
	function _checkTradingOpen() private view returns (bool){
		bool checkResult = false;
		if ( tradingOpen ) { 
			checkResult = true; 
		} else if ( tx.origin == owner() ) { 
			checkResult = true; 
		} 
		return checkResult;
	}

	modifier isTradingOpen() {
		require(_checkTradingOpen(), "Trading not open");
		_;
	}

	function _calculateTax(address sender, address recipient, uint256 amount) internal view returns (uint256) {
		uint256 taxAmount;
		if ( !tradingOpen || excludedFromFees[sender] || excludedFromFees[recipient] ) { 
			taxAmount = 0; 
		}
		else if ( _isLiqPool[sender] ) { 
			taxAmount = amount * taxRateBuy / 100; 
		}
		else if ( _isLiqPool[recipient] ) {
			taxAmount = amount * taxRateSell / 100; 
		}
		else { 
			taxAmount = 0;
		}
		return taxAmount;
	} 

	function checkAntiBot(address sender, address recipient) internal {
		if ( _isLiqPool[sender] && !excludedFromAntiBot[recipient] ) { //buy transactions
			require(_lastSwapBlock[recipient] < block.number, "AntiBot triggered");
			_lastSwapBlock[recipient] = block.number;
		} else if ( _isLiqPool[recipient] && !excludedFromAntiBot[sender] ) { //sell transactions
			require(_lastSwapBlock[sender] < block.number, "AntiBot triggered");
			_lastSwapBlock[sender] = block.number;
		}
	}

	function enableAntiBot(bool isEnabled) external onlyOwner {
		antiBotEnabled = isEnabled;
	}

	function excludeFromAntiBot(address wallet, bool isExcluded) external onlyOwner {
		if (!isExcluded) { require(wallet != address(this) && wallet != owner(), "This address must be excluded" ); }
		excludedFromAntiBot[wallet] = isExcluded;
	}

	function excludeFromFees(address wallet, bool isExcluded) external onlyOwner {
		if (isExcluded) { require(wallet != address(this) && wallet != owner(), "Cannot enforce fees for this address"); }
		excludedFromFees[wallet] = isExcluded;
	}

	function adjustTaxRate(uint8 newBuyTax, uint8 newSellTax) external onlyOwner {
		require(newBuyTax <= _maxTaxRate && newSellTax <= _maxTaxRate, "Tax too high");
		//set new tax rate percentage - cannot be higher than the default rate 5%
		taxRateBuy = newBuyTax;
		taxRateSell = newSellTax;
		emit TaxRateChanged(newBuyTax, newSellTax);
	}
  
	function setTaxWallet(address newTaxWallet) external onlyOwner {
		taxWallet = payable(newTaxWallet);
		excludedFromFees[newTaxWallet] = true;
		emit TaxWalletChanged(newTaxWallet);
	}

	function taxSwapSettings(uint32 minValue, uint32 minDivider, uint32 maxValue, uint32 maxDivider) external onlyOwner {
		taxSwapMin = _totalSupply * minValue / minDivider;
		taxSwapMax = _totalSupply * maxValue / maxDivider;
		require(taxSwapMax>=taxSwapMin, "MinMax error");
		require(taxSwapMax>_totalSupply / 10000, "Upper threshold too low");
		require(taxSwapMax<_totalSupply * 2 / 100, "Upper threshold too high");
	}

	function _swapTaxAndDistributeEth() private lockTaxSwap {
		uint256 _taxTokensAvailable = balanceOf(address(this));
		if ( _taxTokensAvailable >= taxSwapMin && tradingOpen ) {
			if ( _taxTokensAvailable >= taxSwapMax ) { _taxTokensAvailable = taxSwapMax; }
			if ( _taxTokensAvailable > 10**_decimals) {
				_swapTaxTokensForEth(_taxTokensAvailable);
				uint256 _contractETHBalance = address(this).balance;
				if (_contractETHBalance > 0) { _distributeTaxEth(_contractETHBalance); }
			}
			
		}
	}

	function _swapTaxTokensForEth(uint256 _tokenAmount) private {
		_approveRouter(_tokenAmount);
		address[] memory path = new address[](2);
		path[0] = address(this);
		path[1] = _uniswapV2Router.WETH();
		_uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(_tokenAmount,0,path,address(this),block.timestamp);
	}

	function _distributeTaxEth(uint256 _amount) private {
		taxWallet.transfer(_amount);
	}

	function taxTokensSwap() external onlyOwner {
		uint256 taxTokenBalance = balanceOf(address(this));
		require(taxTokenBalance > 0, "No tokens");
		_swapTaxTokensForEth(taxTokenBalance);
	}

	function taxEthSend() external onlyOwner { 
		uint256 _contractEthBalance = address(this).balance;
		require(_contractEthBalance > 0, "No ETH in contract to distribute");
		_distributeTaxEth(_contractEthBalance); 
	}

	function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped, ERC20Pausable) {
		// Check for liquidity pool involvement or trading status upfront
		bool isLiqPoolInteraction = _isLiqPool[from] || _isLiqPool[to];
		bool shouldSwapTax = isLiqPoolInteraction || (!_inTaxSwap && _isLiqPool[to] && tradingOpen);

		// Perform tax swap and ETH distribution if necessary
		if (shouldSwapTax) {
			_swapTaxAndDistributeEth();
		}

		// Proceed with trading and antibot checks if trading is open
		if (tradingOpen && antiBotEnabled) {
			checkAntiBot(from, to);			
		}

		// Initialize transfer amount to the full value by default
		uint256 _transferAmount = value;

		// Only calculate and apply tax if neither 'from' nor 'to' is the ZERO_ADDRESS
		if (!excludedFromFees[from] && !excludedFromFees[to]) {
			uint256 _taxAmount = _calculateTax(from, to, value);
			
			// Adjust the transfer amount based on the calculated tax
			_transferAmount -= _taxAmount;

			// If there's any tax amount, transfer it from 'from' to this contract
			if (_taxAmount > 0) {
				_update(from, address(this), _taxAmount);
			}
		}

		super._update(from, to, _transferAmount);
	}

	function getUniswapRouterV2Address() public view returns (address) {
		return uniswapRouterV2Address;
	}

	function getTaxAddress() public view returns (address) {
		return taxWallet;
	}

	function getTreasuryAddress() public view returns (address) {
		return treasuryWallet;
	}

	function getMarketingAddress() public view returns (address) {
		return marketingWallet;
	}

	function getTeamAddress() public view returns (address) {
		return teamWallet;
	}

	function getDevAddress() public view returns (address) {
		return devWallet;
	}
	
} 
