// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract TORC2 is ERC20, ERC20Burnable, ERC20Permit, AccessControl {

	uint8 constant _maxTaxRate = 5; 
	uint8 public taxRateBuy; 
	uint8 public taxRateSell;

	uint256 constant _treasuryAmount = 100_000_000;
	uint256 constant _devFundAmount = 100_000_000;
	uint256 constant _marketingAmount = 100_000_000;
	uint256 constant _liquidityPoolAmount = 100_000_000;
	uint256 constant _teamAmount = 32_000_000;

	uint256 public taxSwapMin; 
	uint256 public taxSwapMax;

	address payable private taxWallet;
	address payable public treasuryWallet;
	address payable public marketingWallet;
	address payable public teamWallet;
	address payable public devWallet;
	address payable public uniswapRouterV2Address;

	mapping (address => bool) public excludedFromFees;
	mapping (address => bool) private _isLiqPool; 


    constructor(address _taxWallet, address _treasuryWallet, address _devWallet, address _marketingWallet, address _teamWallet) ERC20("Torc", "TORC") ERC20Permit("Torc") {

		taxWallet = payable(_taxWallet);
		treasuryWallet = payable(_treasuryWallet);
		devWallet = payable(_devWallet);
		marketingWallet = payable(_marketingWallet);
		teamWallet = payable(_teamWallet);

		taxSwapMin = totalSupply() * 10 / 10000; 
		taxSwapMax = totalSupply() * 50 / 10000; 
		
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

        _distributeInitialBalances();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
		
    }

	function _distributeInitialBalances() internal {
		_mint(devWallet, _devFundAmount * 10 ** decimals());
		_mint(treasuryWallet, _treasuryAmount * 10 ** decimals());
		_mint(marketingWallet, _marketingAmount * 10 ** decimals());
		_mint(teamWallet, _teamAmount * 10 ** decimals());
		_mint(msg.sender, _liquidityPoolAmount * 10 ** decimals()); 
	}

	function excludeFromFees(address wallet, bool isExcluded) external onlyRole(DEFAULT_ADMIN_ROLE) {
		if (isExcluded) { 
			require(wallet != address(this) && hasRole(DEFAULT_ADMIN_ROLE, wallet), "Cannot enforce fees for this address");  
		} 

		excludedFromFees[wallet] = isExcluded;
	}

	function setLiquidityPool(address wallet, bool isLiquidityPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
		_isLiqPool[wallet] = isLiquidityPool;
	}

	function setTaxRate(uint8 buyRate, uint8 sellRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
		require(buyRate <= _maxTaxRate && sellRate <= _maxTaxRate, "Tax rate cannot exceed 5%"); 
		taxRateBuy = buyRate;
		taxRateSell = sellRate;
	}

	function _calculateTax(address sender, address recipient, uint256 amount) internal view returns (uint256) {
		uint256 taxAmount;
		if ( excludedFromFees[sender] || excludedFromFees[recipient] ) { 
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

	function _update(address from, address to, uint256 value) internal override(ERC20) {  
		// Check for liquidity pool involvement or trading status upfront
		bool isLiqPoolInteraction = _isLiqPool[from] || _isLiqPool[to];

		// // Perform tax swap and ETH distribution if necessary
		// if (shouldSwapTax) {
		// 	_swapTaxAndDistributeEth();
		// }

		
		// Initialize transfer amount to the full value by default
		uint256 _transferAmount = value;

		// Only apply tax if neither sender nor recipient is excluded from fees and the transaction involves a liquidity pool
		if (!excludedFromFees[from] && !excludedFromFees[to] && isLiqPoolInteraction) {
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



}