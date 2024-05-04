// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./libraries/Ownable.sol";
import "./libraries/Address.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';


contract TORC is Context, IERC20, Ownable {
    using Address for address;

    //Mapping section for better tracking.
    mapping(address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedFromFee;

    //Loging and Event Information for better troubleshooting.
    event Log(string, uint256);
    event AuditLog(string, address);
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );
    event SwapTokensForETH(uint256 amountIn, address[] path);

    //Supply Definition.
    uint256 private _tTotal = 432_000_000 ether;
    uint256 private _tFeeTotal;

    //Token Definition.
    string public constant name = "Torc";
    string public constant symbol = "TORC";
    uint8 public constant decimals = 18;

    //Definition of Wallets for Marketing or team.
    address payable public treasuryWallet = payable(0xD335c5E36F1B19AECE98b78e9827a9DF76eE29E6);
    address payable public devWallet = payable(0xE4eEc0C7e825f988aEEe7d05BE579519532E94E5);
    address payable public teamWallet = payable(0x000000000000000000000000000000000000dEaD); 
    address payable public ownerWallet = payable(0x9767a2B120614F526e923DAAF89843EC7C2292d7);

    //Taxes Definition.
    uint public buyFee = 300; // 3%
    uint256 public sellFee = 300; // 3%
    uint256 public minimumTokensBeforeSwap = 10_000 ether;

    //Router and Pair Configuration.
    IUniswapV2Router02 public immutable uniswapV2Router;
    address public immutable uniswapV2Pair;
    address private immutable WETH;

    //Tracking of Automatic Swap vs Manual Swap.
    bool public inSwapAndLiquify;
    bool public swapAndLiquifyEnabled = true;
    bool public tradingEnabled = false;

    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    constructor() {
        _tOwned[_msgSender()] = 172_800_000 ether; // 40% of the total supply, for Liquidity Pool
        _tOwned[treasuryWallet] = 129_600_000 ether; // 30% of the total supply
        _tOwned[devWallet] = 86_400_000 ether; // 20% of the total supply
        _tOwned[teamWallet] = 43_200_000 ether; // 10% of the total supply

        address currentRouter;
        //Adding Variables for all the routers for easier deployment for our customers.
        if (block.chainid == 56) {
            currentRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PCS Router
        } else if (block.chainid == 97) {
            currentRouter = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1; // PCS Testnet
        } else if (block.chainid == 43114) {
            currentRouter = 0x60aE616a2155Ee3d9A68541Ba4544862310933d4; //Avax Mainnet
        } else if (block.chainid == 137) {
            currentRouter = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff; //Polygon Ropsten
        } else if (block.chainid == 6066) {
            currentRouter = 0x4169Db906fcBFB8b12DbD20d98850Aee05B7D889; //Tres Leches Chain
        } else if (block.chainid == 250) {
            currentRouter = 0xF491e7B69E4244ad4002BC14e878a34207E38c29; //SpookySwap FTM
        } else if (block.chainid == 42161) {
            currentRouter = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506; //Arbitrum Sushi
		} else if (block.chainid == 11155111) {
			currentRouter = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008; //Sepolia Testnet
        } else if (
            block.chainid == 1 || block.chainid == 4 || block.chainid == 5 || block.chainid == 1337 || block.chainid == 14075
        ) {
            currentRouter = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; //Mainnet
        } else {
            revert("You're not Blade");
        }

        //End of Router Variables.
        //Create Pair in the contructor, this may fail on some blockchains and can be done in a separate line if needed.
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(currentRouter);
        WETH = _uniswapV2Router.WETH();
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), WETH);
        uniswapV2Router = _uniswapV2Router;
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;

        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    //Readable Functions.
    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _tOwned[account];
    }

    //ERC 20 Standard Transfer Functions
    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    //ERC 20 Standard Allowance Function
    function allowance(
        address _owner,
        address spender
    ) public view override returns (uint256) {
        return _allowances[_owner][spender];
    }

    //ERC 20 Standard Approve Function
    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    //ERC 20 Standard Transfer From
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        uint currentAllowance = _allowances[sender][_msgSender()];
        require(
            currentAllowance >= amount,
            "ERC20: transfer amount exceeds allowance"
        );
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), currentAllowance - amount);
        return true;
    }

    //ERC 20 Standard increase Allowance
    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender] + addedValue
        );
        return true;
    }

    //ERC 20 Standard decrease Allowance
    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender] - subtractedValue
        );
        return true;
    }

    //Approve Function
    function _approve(address _owner, address spender, uint256 amount) private {
        require(_owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }

    //Transfer function, validate correct wallet structure, take fees, and other custom taxes are done during the transfer.
    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        require(_tOwned[from] >= amount, "ERC20: transfer amount exceeds balance");
        if (!tradingEnabled) {
            require(from != uniswapV2Pair && to != uniswapV2Pair, "Trading is disabled");
        }

        //Adding logic for automatic swap.
        uint256 contractTokenBalance = balanceOf(address(this));
        bool overMinimumTokenBalance = contractTokenBalance >= minimumTokensBeforeSwap;
        uint fee = 0;
        //if any account belongs to _isExcludedFromFee account then remove the fee
        if (
            !inSwapAndLiquify &&
            from != uniswapV2Pair &&
            overMinimumTokenBalance &&
            swapAndLiquifyEnabled
        ) {
            swapAndLiquify();
        }
        if (to == uniswapV2Pair && !_isExcludedFromFee[from]) {
            fee = (sellFee * amount) / 10_000;
        }
        if (from == uniswapV2Pair && !_isExcludedFromFee[to]) {
            fee = (buyFee * amount) / 10_000;
        }
        amount -= fee;
        if (fee > 0) {
            _tokenTransfer(from, address(this), fee);            
        }
        _tokenTransfer(from, to, amount);
    }

    //Swap Tokens for BNB or to add liquidity either automatically or manual, by default this is set to manual.
    //Corrected newBalance bug, it sending bnb to wallet and any remaining is on contract and can be recoverred.
    function swapAndLiquify() public lockTheSwap {
        uint256 totalTokens = balanceOf(address(this));
        swapTokensForEth(totalTokens);

        uint ethBalance = address(this).balance;
        transferToAddressETH(treasuryWallet, ethBalance);
    }

    //swap for eth is to support the converstion of tokens to weth during swapandliquify this is a supporting function
    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this), // The contract
            block.timestamp
        );

        emit SwapTokensForETH(tokenAmount, path);
    }

    //ERC 20 standard transfer, only added if taking fees to countup the amount of fees for better tracking and split purpose.
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        _tOwned[sender] -= amount;
        _tOwned[recipient] += amount;

        emit Transfer(sender, recipient, amount);
    }

    function isExcludedFromFee(address account) external view returns (bool) {
        return _isExcludedFromFee[account];
    }

    //exclude wallets from fees, this is needed for launch or other contracts.
    function excludeFromFee(address account) external onlyOwner {
        _isExcludedFromFee[account] = true;
        emit AuditLog(
            "We have excluded the following walled in fees:",
            account
        );
    }

    //include wallet back in fees.
    function includeInFee(address account) external onlyOwner {
        _isExcludedFromFee[account] = false;
        emit AuditLog(
            "We have including the following walled in fees:",
            account
        );
    }

    //Automatic Swap Configuration.
    function setTokensToSwap(
        uint256 _minimumTokensBeforeSwap
    ) external onlyOwner {
        require(
            _minimumTokensBeforeSwap >= 1,
            "You need to enter more than 1 tokens."
        );
        minimumTokensBeforeSwap = _minimumTokensBeforeSwap;
        emit Log(
            "We have updated minimunTokensBeforeSwap to:",
            minimumTokensBeforeSwap
        );
    }

    function setSwapAndLiquifyEnabled(bool _enabled) external onlyOwner {
        require(swapAndLiquifyEnabled != _enabled, "Value already set");
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    //set a new marketing wallet.
    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        require(_treasuryWallet != address(0), "setTreasuryWallet: ZERO");
        treasuryWallet = payable(_treasuryWallet);
        emit AuditLog("We have Updated the TreasuryWallet:", treasuryWallet);
    }

    //set a new team wallet.
    function setDevWallet(address _devWallet) external onlyOwner {
        require(_devWallet != address(0), "setDevWallet: ZERO");
        devWallet = payable(_devWallet);
        emit AuditLog("We have Updated the DevWallet:", devWallet);
    }



    function transferToAddressETH(
        address payable recipient,
        uint256 amount
    ) private {
        if (amount == 0) return;
        (bool succ, ) = recipient.call{value: amount}("");
        require(succ, "Transfer failed.");
    }

    //to recieve ETH from uniswapV2Router when swaping
    receive() external payable {}

    // Withdraw ETH that's potentially stuck in the Contract
    function recoverETHfromContract() external onlyOwner {
        uint ethBalance = address(this).balance;
        (bool succ, ) = payable(treasuryWallet).call{value: ethBalance}("");
        require(succ, "Transfer failed");
        emit AuditLog(
            "We have recover the stock eth from contract.",
            treasuryWallet
        );
    }

    // Withdraw ERC20 tokens that are potentially stuck in Contract
    function recoverTokensFromContract(
        address _tokenAddress,
        uint256 _amount
    ) external onlyOwner {
        require(
            _tokenAddress != address(this),
            "Owner can't claim contract's balance of its own tokens"
        );
        bool succ = IERC20(_tokenAddress).transfer(treasuryWallet, _amount);
        require(succ, "Transfer failed");
        emit Log("We have recovered tokens from contract:", _amount);
    }

    //Final Dev notes, this code has been tested and audited, last update to code was done to re-add swapandliquify function to the transfer as option, is recommended to be used manually instead of automatic.
}