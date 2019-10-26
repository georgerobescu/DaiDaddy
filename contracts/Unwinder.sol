pragma solidity ^0.5.7;

/// @title DaiDaddy 2.0: Pay back your debt by unwinding your CDP
/// @author Chris Maree

import "./SaiTubInterface.sol";
import "./MedianizerInterface.sol";
import "./KyberNetworkProxyInterface.sol";
import "./ERC20Interface.sol";

contract Unwinder {
    
    // constants
    uint256 safeNoLiquidationRatio = 151 * 10 ** 16;  // a value of 1.51, just above the liquidation amount of a CDP
    ERC20 constant internal ETH_TOKEN_ADDRESS = ERC20(0x00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee);

    
    // contract instances
    SaiTub public saiTubContract;
    Medianizer public medianizerContract;
    KyberNetworkProxy public kyberNetworkProxyContract;
    ERC20 public daiContract;

    // state variables
    mapping (address => bytes32)  public  cupOwners; // prove that you owned the CDP before transfering it to DaiDaddy

    constructor(address _saiTubAddress,
        address _medianizerAddress,
        address _KyberNetworkProxyAddress,
        address _daiTokenAddress)
    public {
        saiTubContract = SaiTub(_saiTubAddress);
        medianizerContract = Medianizer(_medianizerAddress);
        kyberNetworkProxyContract = KyberNetworkProxy(_KyberNetworkProxyAddress);
        daiContract = ERC20(_daiTokenAddress);
    }

    // round number a to b decimal points
    function ceil(uint a, uint m) public pure returns (uint ) {
        return ((a + m - 1) / m) * m;
    }
    
    // takes in all the information about a CDP and returns the current collateralization ratio scaled *10 ^ 18
    // uint256  ink             Locked collateral (in Weth)
    // uint256  art             Outstanding normalised debt(including tax)
    // uint256  etherPrice      Current ether Price
    // uint256  wpRatio         Weth to Peth Ratio
    function collateralizationRatio(uint256 ink, uint256 art, uint256 etherPrice, uint256 wpRatio) public pure returns (uint256) {
        uint256 cr = (ink * etherPrice * wpRatio) / (art * 10 ** 18);
        return cr;
    }
    
    // returns an interger representing how many unwinds are needed for a given collateralization ratio. The use of
    // the ceil function and the scaling is to act as a round up
    function unwindsNeeded(uint256 cr) public pure returns(uint256){
        //1.5 here represents the collateralization ratio needed to not get liquidated as a CDP on makerDao
        uint256 repaymentsNeeded = (1 * 10 ** (18 * 2)) / (cr - 1.5 * 10 ** 18);
        return ceil(repaymentsNeeded / (10 ** 14), 10000) / 10000;
    }
    
    function freeableCollateral(uint256 ink, uint256 art, uint256 etherPrice, uint256 wpRatio) public view returns (uint256) {
        return (ink * wpRatio) / (10 ** 18) - (art * safeNoLiquidationRatio) / etherPrice;
    }
    
    // See how much Dai can be gained from trading against keyber for the freed Ether
    function ethToDaiGetKyberPrice(uint256 _etherToSell) public view returns (uint, uint) {
        return kyberNetworkProxyContract.getExpectedRate(address(ETH_TOKEN_ADDRESS), address(daiContract), _etherToSell);
    }

    function proveOwnershipOfCDP(bytes32 _cup) public {
        (address lad,,,) = saiTubContract.cups(_cup);
        require(lad == msg.sender, "Only the current owner of the cup can prove ownership");
        cupOwners[msg.sender] = _cup;
    }

    /**
     * @dev Gets the conversion rate for the destToken given the srcQty.
     * @param srcToken source token contract address
     * @param srcQty amount of source tokens
     * @param destToken destination token contract address
     */
    function getConversionRates(
        address srcToken,
        uint srcQty,
        address destToken
    ) public
        view
        returns (uint, uint)
    {
        return kyberNetworkProxyContract.getExpectedRate(srcToken, destToken, srcQty);

    }

    /**
     * @dev Swap the user's ERC20 token to another ERC20 token/ETH
     * @param srcToken source token contract address
     * @param srcQty amount of source tokens
     * @param destToken destination token contract address
     * @param destAddress address to send swapped tokens to
     * @param maxDestAmount address to send swapped tokens to
     */
    function executeSwap(
        address srcToken,
        uint srcQty,
        address destToken,
        address destAddress,
        uint maxDestAmount
    ) public {
        uint minConversionRate;

        // Check that the token transferFrom has succeeded
        require(ERC20(srcToken).transferFrom(msg.sender, address(this), srcQty), "Token transfer did not complete successfully");

        // Mitigate ERC20 Approve front-running attack, by initially setting
        // allowance to 0
        require(ERC20(srcToken).approve(address(kyberNetworkProxyContract), 0), "Token aprove did not complete successfully");

        // Set the spender's token allowance to tokenQty
        require(ERC20(srcToken).approve(address(kyberNetworkProxyContract), srcQty),"Token aprove did not complete successfully");

        // Get the minimum conversion rate
        (minConversionRate,) = kyberNetworkProxyContract.getExpectedRate(srcToken, destToken, srcQty);

        // Swap the ERC20 token and send to destAddress
        kyberNetworkProxyContract.trade(
            srcToken,
            srcQty,
            destToken,
            destAddress,
            maxDestAmount,
            minConversionRate,
            address(0) //walletId for fee sharing program
        );
    }
}

