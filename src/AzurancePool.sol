// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MintableERC20.sol";
import "./interfaces/IAzurancePool.sol";
import "./interfaces/IAzuranceCondition.sol";

contract AzurancePool is IAzurancePool {
    uint256 private _multiplier;
    uint256 private _maturityBlock;
    uint256 private _staleBlock;

    uint256 private _fee;
    address private _feeTo;

    uint256 private _rBuy;
    uint256 private _rSell;

    IERC20 private _underlyingToken;
    MintableERC20 private _buyerToken;
    MintableERC20 private _sellerToken;

    IAzuranceCondition private _condition;

    State private _status;

    // Constructor
    constructor(
        uint256 multiplier_,
        uint256 maturityBlock_,
        uint256 staleBlock_,
        address underlyingToken_,
        uint256 fee_,
        address feeTo_,
        address condition_,
        string memory name_,
        string memory symbol_
    ) {
        _multiplier = multiplier_;
        _maturityBlock = maturityBlock_;
        _staleBlock = staleBlock_;

        _fee = fee_;
        _feeTo = feeTo_;

        _underlyingToken = IERC20(underlyingToken_);
        _buyerToken = new MintableERC20(string.concat(name_, "-BUY"), string.concat(symbol_, "-BUY"));
        _sellerToken = new MintableERC20(string.concat(name_, "-SELL"), string.concat(symbol_, "-SELL"));

        _condition = IAzuranceCondition(condition_);

        _status = State.Ongoing;
    }

    modifier onlyNotStale() {
        require(block.number <= _staleBlock, "Azurance: Stable block passed");
        _;
    }

    modifier onlyState(State state_) {
        require(_status == state_, "Azurance: onlystate");
        _;
    }

    modifier onlyNotState(State _state) {
        require(_status != _state, "Azurance: onlyNotState");
        _;
    }

    modifier onlyCondition() {
        require(msg.sender == address(_condition), "Azurance: Only Condition");
        _;
    }

    // Functions
    function buyInsurance(uint256 _amount) external override onlyNotStale onlyState(State.Ongoing) {
        // Gas savings
        uint256 _totalShare = totalShares();

        uint256 _share = 0;
        if (_totalShare == 0) {
            _share = _amount;
        } else {
            _share = (_amount * _totalShare) / totalValueLocked();
        }

        require(
            (_totalBuyShare() + _share) * _multiplier / 10 ** multiplierDecimals() <= _totalSellShare(),
            "Exceed buy deposit"
        );

        _underlyingToken.transferFrom(msg.sender, address(this), _amount);
        _buyerToken.mint(msg.sender, _share);

        emit InsuranceBought(msg.sender, address(_underlyingToken), _amount);
    }

    function sellInsurance(uint256 _amount) external override onlyNotStale onlyState(State.Ongoing) {
        // Gas savings
        uint256 _totalShare = totalShares();

        uint256 _share = 0;
        if (_totalShare == 0) {
            _share = _amount;
        } else {
            _share = (_amount * _totalShare) / totalValueLocked();
        }

        _underlyingToken.transferFrom(msg.sender, address(this), _amount);
        _sellerToken.mint(msg.sender, _share);

        emit InsuranceSold(msg.sender, address(_underlyingToken), _amount);
    }

    function unlockClaim() external override onlyState(State.Ongoing) onlyCondition {
        // check from oracle
        _status = State.Claimable;
        _settle();
        emit StateChanged(State.Ongoing, State.Claimable);
    }

    function unlockMaturity() external override onlyState(State.Ongoing) {
        require(block.number > _maturityBlock, "Maturity time not met");
        _status = State.Matured;
        _settle();
        emit StateChanged(State.Ongoing, State.Matured);
    }

    function unlockTerminate() external override onlyState(State.Ongoing) onlyCondition {
        _status = State.Terminated;
        _settle();
        emit StateChanged(State.Ongoing, State.Terminated);
    }

    function checkUnlockClaim() external override {
        _condition.checkUnlockClaim(address(this));
    }

    function checkUnlockTerminate() external override {
        _condition.checkUnlockTerminate(address(this));
    }

    function withdraw(uint256 _buyerAmount, uint256 _sellerAmount) external override onlyNotState(State.Ongoing) {
        uint256 _withdrawAmount;
        if (_status == State.Claimable) {
            _withdrawAmount = getAmountClaimable(_buyerAmount, _sellerAmount);
        } else if (_status == State.Matured) {
            _withdrawAmount = getAmountMatured(_buyerAmount, _sellerAmount);
        } else {
            _withdrawAmount = getAmountTerminated(_buyerAmount, _sellerAmount);
        }
        _withdraw(_buyerAmount, _sellerAmount, _withdrawAmount);
        _settle();
        emit Withdrew(address(_underlyingToken), _withdrawAmount, msg.sender);
    }

    function withdrawFee(uint256 _amount) external {
        require(_status != State.Ongoing, "Azurance: Contract is Ongoing");
        // logic to withdraw platform fees
    }

    // read functions
    function getAmountClaimable(uint256 _buyerAmount, uint256 _sellerAmount) public view override returns (uint256) {
        // Gas savings
        uint256 _totalBuyerShare = settledBuyShare();
        uint256 _totalSellerShare = settledSellShare();
        uint256 _totalShare = settledShare();
        uint256 _totalValueLocked = totalValueLocked();

        if (_status == State.Ongoing) {
            _totalBuyerShare = totalBuyShare();
            _totalSellerShare = totalSellShare();
            _totalShare = totalShares();
        }

        uint256 _adjustedBuyerShare = _totalBuyerShare * _multiplier / 10 ** multiplierDecimals();
        uint256 _adjustedSellerShare = _totalSellerShare * 10 ** multiplierDecimals() / _multiplier;
        _totalShare = _adjustedBuyerShare + _adjustedSellerShare;

        uint256 _totalBuyerValue = (_adjustedBuyerShare * _totalValueLocked) / _totalShare;
        uint256 _totalSellerValue = (_adjustedSellerShare * _totalValueLocked) / _totalShare;

        uint256 _withdrewAmount = 0;
        if (_buyerAmount > 0) {
            _withdrewAmount += _getPortion(_buyerAmount, _totalBuyerShare, _totalBuyerValue);
        }
        if (_sellerAmount > 0) {
            _withdrewAmount += _getPortion(_sellerAmount, _totalSellerShare, _totalSellerValue);
        }

        return _withdrewAmount;
    }

    function getAmountMatured(uint256 _buyerAmount, uint256 _sellerAmount) public view override returns (uint256) {
        // Gas savings
        uint256 _totalBuyerShare = settledBuyShare();
        uint256 _totalSellerShare = settledSellShare();
        uint256 _totalShare = settledShare();
        uint256 _totalValueLocked = totalValueLocked();

        if (_status == State.Ongoing) {
            _totalBuyerShare = totalBuyShare();
            _totalSellerShare = totalSellShare();
            _totalShare = totalShares();
        }

        uint256 _adjustedBuyerShare = _totalBuyerShare * 10 ** multiplierDecimals() / _multiplier;
        uint256 _adjustedSellerShare = _totalSellerShare * _multiplier / 10 ** multiplierDecimals();
        _totalShare = _adjustedBuyerShare + _adjustedSellerShare;

        uint256 _totalBuyerValue = (_adjustedBuyerShare * _totalValueLocked) / _totalShare;
        uint256 _totalSellerValue = (_adjustedSellerShare * _totalValueLocked) / _totalShare;

        uint256 _withdrewAmount = 0;
        if (_buyerAmount > 0) {
            _withdrewAmount += _getPortion(_buyerAmount, _totalBuyerShare, _totalBuyerValue);
        }
        if (_sellerAmount > 0) {
            _withdrewAmount += _getPortion(_sellerAmount, _totalSellerShare, _totalSellerValue);
        }

        return _withdrewAmount;
    }

    function getAmountTerminated(uint256 _buyerAmount, uint256 _sellerAmount) public view override returns (uint256) {
        uint256 _totalBuyerShare = settledBuyShare();
        uint256 _totalSellerShare = settledSellShare();
        uint256 _totalShare = settledShare();
        uint256 _tvl = totalValueLocked();

        if (_status == State.Ongoing) {
            _totalBuyerShare = totalBuyShare();
            _totalSellerShare = totalSellShare();
            _totalShare = totalShares();
        }

        uint256 _totalBuyerValue = (_totalBuyerShare * _tvl) / _totalShare;
        uint256 _totalSellerValue = (_totalSellerShare * _tvl) / _totalShare;

        uint256 _withdrewAmount = 0;
        if (_buyerAmount > 0) {
            _withdrewAmount += _getPortion(_buyerAmount, _totalBuyerShare, _totalBuyerValue);
        }
        if (_sellerAmount > 0) {
            _withdrewAmount += _getPortion(_sellerAmount, _totalSellerShare, _totalSellerValue);
        }

        return _withdrewAmount;
    }

    function totalValueLocked() public view override returns (uint256) {
        return _totalValueLocked();
    }

    function totalShares() public view override returns (uint256) {
        return _totalShares();
    }

    function totalBuyShare() public view override returns (uint256) {
        return _totalBuyShare();
    }

    function totalSellShare() public view override returns (uint256) {
        return _totalSellShare();
    }

    function settledShare() public view override returns (uint256) {
        return _settledShare();
    }

    function settledBuyShare() public view override returns (uint256) {
        return _settledBuyShare();
    }

    function settledSellShare() public view override returns (uint256) {
        return _settledSellShare();
    }

    function multiplierDecimals() public pure override returns (uint256) {
        return 6;
    }

    function feeDecimals() public pure override returns (uint256) {
        return 6;
    }

    function staleBlock() external view override returns (uint256) {
        return _staleBlock;
    }

    function status() external view override returns (State) {
        return _status;
    }

    function underlyingToken() external view override returns (address) {
        return address(_underlyingToken);
    }

    function multiplier() external view override returns (uint256) {
        return _multiplier;
    }

    function fee() external view override returns (uint256) {
        return _fee;
    }

    function feeTo() external view override returns (address) {
        return _feeTo;
    }

    function condition() external view override returns (address) {
        return address(_condition);
    }

    function maturityBlock() external view override returns (uint256) {
        return _maturityBlock;
    }

    function buyerToken() external view override returns (address) {
        return address(_buyerToken);
    }

    function sellerToken() external view override returns (address) {
        return address(_sellerToken);
    }

    // internal functions
    function _totalValueLocked() internal view returns (uint256) {
        return _underlyingToken.balanceOf(address(this));
    }

    function _totalShares() internal view returns (uint256) {
        return _totalBuyShare() + _totalSellShare();
    }

    function _totalBuyShare() internal view returns (uint256) {
        return _buyerToken.totalSupply();
    }

    function _totalSellShare() internal view returns (uint256) {
        return _sellerToken.totalSupply();
    }

    function _settledShare() internal view returns (uint256) {
        return _settledBuyShare() + _settledSellShare();
    }

    function _settledBuyShare() internal view returns (uint256) {
        return _rBuy;
    }

    function _settledSellShare() internal view returns (uint256) {
        return _rSell;
    }

    function _getPortion(uint256 _share, uint256 _totalShare, uint256 _totalValue) internal pure returns (uint256) {
        return (_share * _totalValue) / _totalShare;
    }

    function _settle() internal {
        _rBuy = _totalBuyShare();
        _rSell = _totalSellShare();
    }

    function _withdraw(uint256 _buyerAmount, uint256 _sellerAmount, uint256 _withdrewAmount) internal {
        if (_buyerAmount > 0) {
            _buyerToken.burn(msg.sender, _buyerAmount);
        }
        if (_sellerAmount > 0) {
            _sellerToken.burn(msg.sender, _sellerAmount);
        }
        require(_withdrewAmount > 0, "Amount out must be greater than 0");
        _transferOut(_withdrewAmount);
    }

    function _transferOut(uint256 _amount) internal virtual {
        _underlyingToken.transfer(msg.sender, _amount);
    }
}
