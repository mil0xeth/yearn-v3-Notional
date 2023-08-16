// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {BaseTokenizedStrategy} from "@tokenized-strategy/BaseTokenizedStrategy.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Comet, CometRewards} from "./interfaces/Compound/V3/CompoundV3.sol";
import {IOracle} from "./interfaces/IOracle.sol";
// Uniswap V3 Swapper
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

contract CompoundV3Lender is BaseTokenizedStrategy, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    address internal constant weth = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    Comet public immutable comet;

    // Rewards Stuff
    CometRewards public constant rewardsContract =
        CometRewards(0x45939657d1CA34A8FA39A924B71D28Fe8431e581);

    IOracle public constant rewardOracle =
        IOracle(0x2A8758b7257102461BC958279054e372C2b1bDE6);

    uint256 public percentOut = 9_000;

    address public immutable rewardToken;

    // Repersents if we should claim rewards. Default to true.
    bool public claimRewards = true;

    constructor(
        address _asset,
        string memory _name,
        address _comet
    ) BaseTokenizedStrategy(_asset, _name) {
        comet = Comet(_comet);

        require(comet.baseToken() == _asset, "wrong asset");

        ERC20(asset).safeApprove(_comet, type(uint256).max);

        // Set the rewardToken token we will get.
        rewardToken = rewardsContract.rewardConfig(_comet).token;

        // Set the needed variables for the Uni Swapper
        // Base will be weth.
        base = weth;
        // UniV3 mainnet router.
        router = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
        // Set the min amount for the swapper to sell
        minAmountToSell = 1e14;
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permsionless and thus can be sandwhiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attemppt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        comet.supply(asset, _amount);
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permsionless and thus can be sandwhiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting puroposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // Need the balance updated
        comet.accrueAccount(address(this));

        comet.withdraw(
            asset,
            Math.min(comet.balanceOf(address(this)), _amount)
        );
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // Update balances.
        comet.accrueAccount(address(this));
        // Only sell and reinvest if we arent shutdown
        if (!TokenizedStrategy.isShutdown() && claimRewards) {
            // Claim and sell any rewards to `asset`. We already accrued.
            rewardsContract.claim(address(comet), address(this), false);

            // Cache reward token.
            address _rewardToken = rewardToken;
            uint256 balance = ERC20(_rewardToken).balanceOf(address(this));
            // The uni swapper will do min checks on _reward.
            _swapFrom(_rewardToken, asset, balance, _getAmountOut(balance));

            // deposit any loose funds
            uint256 looseAsset = ERC20(asset).balanceOf(address(this));
            if (looseAsset > 0) {
                comet.supply(asset, looseAsset);
            }
        }

        _totalAssets =
            comet.balanceOf(address(this)) +
            ERC20(asset).balanceOf(address(this));
    }

    // Treats USDC as 1 - 1 for USD. `percentOut` can be adjusted if this is not true.
    function _getAmountOut(uint256 _amount) internal view returns (uint256) {
        uint256 _percentOut = percentOut;
        // Dont call the oracle if percent out is 0.
        if (_percentOut == 0) return 0;
        // asset is 1e6 answer is 1e18 and _amount 1e18. So 6 + 2 + 12 = 1e20.
        return
            (rewardOracle.latestAnswer() * _amount * percentOut) /
            1e20 /
            10_000;
    }

    //These will default to 0.
    //Will need to be manually set if asset is incentized before any harvests
    function setUniFees(
        uint24 _rewardToBase,
        uint24 _baseToAsset
    ) external onlyManagement {
        _setUniFees(rewardToken, base, _rewardToBase);
        _setUniFees(base, asset, _baseToAsset);
    }

    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        minAmountToSell = _minAmountToSell;
    }

    /**
     * @notice Swap the base token between `asset` and `weth`.
     * @dev This can be used for management to change which pool
     * to trade reward tokens.
     */
    function swapBase() external onlyManagement {
        base = base == asset ? weth : asset;
    }

    /**
     * @notice Set the `claimRewards` bool.
     * @dev For management to set if the strategy should claim rewards during reports.
     * Can be turned off due to rewards being turned off or cause of an issue
     * in either the strategy or compound contracts.
     *
     * @param _claimRewards Bool repersenting if rewards should be claimed.
     */
    function setClaimRewards(bool _claimRewards) external onlyManagement {
        claimRewards = _claimRewards;
    }

    /**
     * @notice Set the `percentOut` for {_getAmountOut}.
     * @dev Amount in basis pasis point to expect out based on oracle
     * price. I.E. 9_000 = 90% of the oracle price.
     *
     * NOTE: Can be set to 0 to not use the oracle.
     *
     * @param _percentOut Basis point to set as `percentOut`.
     */
    function setPercentOut(uint256 _percentOut) external onlyManagement {
        percentOut = _percentOut;
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overriden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwhichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The avialable amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return
            TokenizedStrategy.totalIdle() +
            ERC20(asset).balanceOf(address(comet));
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A seperate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        comet.accrueAccount(address(this));
        comet.withdraw(
            asset,
            Math.min(comet.balanceOf(address(this)), _amount)
        );
    }
}
