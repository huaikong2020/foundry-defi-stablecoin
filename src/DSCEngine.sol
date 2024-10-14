// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCEngine__HealthFactorNotImproved();

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier tokenIsAllowed(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscTokenAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscTokenAddress);
    }

    function depositCollateralAndMintDSC(
        address _collateralToken,
        uint256 _collateralAmount,
        uint256 _dscAmount
    ) external {
        depositCollateral(_collateralToken, _collateralAmount);
        mintDSC(_dscAmount);
    }

    function depositCollateral(
        address _collateralTokenAddress,
        uint256 _collateralAmount
    )
        public
        moreThanZero(_collateralAmount)
        tokenIsAllowed(_collateralTokenAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            _collateralTokenAddress
        ] += _collateralAmount;
        emit CollateralDeposited(
            msg.sender,
            _collateralTokenAddress,
            _collateralAmount
        );
        bool success = IERC20(_collateralTokenAddress).transferFrom(
            msg.sender,
            address(this),
            _collateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDSC(
        address _collateralToken,
        uint256 _collateralAmount,
        uint256 dscAmount
    ) external {
        burnDSC(dscAmount);
        redeemCollateral(_collateralToken, _collateralAmount);
    }

    function redeemCollateral(
        address _collateralToken,
        uint256 _collateralAmount
    ) public moreThanZero(_collateralAmount) nonReentrant {
        _redeemCollateral(
            _collateralToken,
            _collateralAmount,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateral(
        address _collateralToken,
        uint256 _collateralAmount,
        address _from,
        address _to
    ) private moreThanZero(_collateralAmount) nonReentrant {
        s_collateralDeposited[_from][_collateralToken] -= _collateralAmount;
        emit CollateralRedeemed(
            _from,
            _to,
            _collateralToken,
            _collateralAmount
        );
        bool success = IERC20(_collateralToken).transfer(
            _to,
            _collateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function mintDSC(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(
        uint256 amountDscToBurn
    ) public moreThanZero(amountDscToBurn) {
        _burnDSC(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _burnDSC(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private moreThanZero(amountDscToBurn) {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOkay();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            collateral,
            totalCollateralToRedeem,
            user,
            msg.sender
        );
        _burnDSC(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
    }

    function getTokenAmountFromUsd(
        address _token,
        uint256 _usdAmount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[_token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return ((_usdAmount * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getHealthFactor() external view returns (uint256) {}

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 healthFactor = _healthFactor(_user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    function _healthFactor(address _user) internal view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 totalCollateralDeposited
        ) = _getAccountInformation(_user);
        uint256 collateralAdjustedForThreshold = (totalCollateralDeposited *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _getAccountInformation(
        address _user
    )
        internal
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralDeposited)
    {
        totalDscMinted = s_DscMinted[_user];
        totalCollateralDeposited = getAccountCollateralDeposited(_user);
        return (totalDscMinted, totalCollateralDeposited);
    }

    function getAccountCollateralDeposited(
        address _user
    ) public view returns (uint256 totalCollateralDeposited) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralDeposited += getUsdValue(token, amount);
        }
        return totalCollateralDeposited;
    }

    function getUsdValue(
        address _token,
        uint256 _amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[_token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) /
            PRECISION;
    }
}
