//SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "./Authorizable.sol";
import "./HigherDimensions.sol";

import "hardhat/console.sol";

contract Wise is ERC20, Authorizable {
    using SafeMath for uint256;
    string private TOKEN_NAME = "Hd Wise";
    string private TOKEN_SYMBOL = "WISE";

    address public HD_CONTRACT;

    // the base number of $WISE per hd (i.e. 0.75 $wise)
    uint256 public BASE_HOLDER_WISE = 750000000000000000;

    // the number of $WISE per hd per day per kg (i.e. 0.25 $wise /hd /day /kg)
    uint256 public WISE_PER_DAY_PER_KG = 250000000000000000;

    // how much wise it costs to skip the cooldown
    uint256 public COOLDOWN_BASE = 100000000000000000000; // base 100
    // how much additional wise it costs to skip the cooldown per kg
    uint256 public COOLDOWN_BASE_FACTOR = 100000000000000000000; // additional 100 per kg
    // how long to wait before skip cooldown can be re-invoked
    uint256 public COOLDOWN_CD_IN_SECS = 86400; // additional 100 per kg

    uint256 public LEVELING_BASE = 25;
    uint256 public LEVELING_RATE = 2;
    uint256 public COOLDOWN_RATE = 3600; // 60 mins

    // uint8 (0 - 255)
    // uint16 (0 - 65535)
    // uint24 (0 - 16,777,216)
    // uint32 (0 - 4,294,967,295)
    // uint40 (0 - 1,099,511,627,776)
    // unit48 (0 - 281,474,976,710,656)
    // uint256 (0 - 1.157920892e77)

    /**
     * Stores staked hd fields (=> 152 <= stored in order of size for optimal packing!)
     */
    struct StakedHdObj {
        // the current kg level (0 -> 16,777,216)
        uint24 kg;
        // when to calculate wise from (max 20/02/36812, 11:36:16)
        uint32 sinceTs;
        // for the skipCooldown's cooldown (max 20/02/36812, 11:36:16)
        uint32 lastSkippedTs;
        // how much this hd has been fed (in whole numbers)
        uint48 eatenAmount;
        // cooldown time until level up is allow (per kg)
        uint32 cooldownTs;
    }

    // redundant struct - can't be packed? (max totalKg = 167,772,160,000)
    uint40 public totalKg;
    uint16 public totalStakedHd;

    StakedHdObj[100001] public stakedHd;

    // Events

    event Minted(address owner, uint256 wiseAmt);
    event Burned(address owner, uint256 wiseAmt);
    event Staked(uint256 tid, uint256 ts);
    event UnStaked(uint256 tid, uint256 ts);

    // Constructor

    constructor(address _hdContract) ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        HD_CONTRACT = _hdContract;
    }

    // "READ" Functions
    // How much is required to be fed to level up per kg

    function dmtLevelingRate(uint256 kg) public view returns (uint256) {
        // need to divide the kg by 100, and make sure the dmt level is at 18 decimals
        return LEVELING_BASE * ((kg / 100)**LEVELING_RATE);
    }

    // when using the value, need to add the current block timestamp as well
    function cooldownRate(uint256 kg) public view returns (uint256) {
        // need to divide the kg by 100

        return (kg / 100) * COOLDOWN_RATE;
    }

    // Staking Functions

    // stake hd, check if is already staked, get all detail for hd such as
    function _stake(uint256 tid) internal {
        HigherDimensions x = HigherDimensions(HD_CONTRACT);

        // verify user is the owner of the hd...
        require(x.ownerOf(tid) == msg.sender, "NOT OWNER");

        // get calc'd values...
        (, , , , , , , uint256 kg) = x.allHigherDimension(tid);
        // if lastSkippedTs is 0 its mean it never have a last skip timestamp
        StakedHdObj memory c = stakedHd[tid];
        uint32 ts = uint32(block.timestamp);
        if (stakedHd[tid].kg == 0) {
            // create staked hd...
            stakedHd[tid] = StakedHdObj(
                uint24(kg),
                ts,
                c.lastSkippedTs > 0 ? c.lastSkippedTs :  uint32(ts - COOLDOWN_CD_IN_SECS),
                uint48(0),
                uint32(ts) + uint32(cooldownRate(kg)) 
            );

            // update snapshot values...
            // N.B. could be optimised for multi-stakes - but only saves 0.5c AUD per hd - not worth it, this is a one time operation.
            totalStakedHd += 1;
            totalKg += uint24(kg);

            // let ppl know!
            emit Staked(tid, block.timestamp);
        }
    }

    // function staking(uint256 tokenId) external {
    //     _stake(tokenId);
    // }

    function stake(uint256[] calldata tids) external {
        for (uint256 i = 0; i < tids.length; i++) {
            _stake(tids[i]);
        }
    }

    /**
     * Calculates the amount of wise that is claimable from a hd.
     */
    function claimableView(uint256 tokenId) public view returns (uint256) {
        StakedHdObj memory c = stakedHd[tokenId];
        if (c.kg > 0) {
            uint256 wisePerDay = ((WISE_PER_DAY_PER_KG * (c.kg / 100)) +
                BASE_HOLDER_WISE);
            uint256 deltaSeconds = block.timestamp - c.sinceTs;
            return deltaSeconds * (wisePerDay / 86400);
        } else {
            return 0;
        }
    }

    // Removed "getHd" to save space

    // struct HdObj {
    //     uint256 kg;
    //     uint256 sinceTs;
    //     uint256 lastSkippedTs;
    //     uint256 eatenAmount;
    //     uint256 cooldownTs;
    //     uint256 requiredmtAmount;
    // }

    // function getHd(uint256 tokenId) public view returns (HdObj memory) {
    //     StakedHdObj memory c = stakedHd[tokenId];
    //     return
    //         HdObj(
    //             c.kg,
    //             c.sinceTs,
    //             c.lastSkippedTs,
    //             c.eatenAmount,
    //             c.cooldownTs,
    //             dmtLevelingRate(c.kg)
    //         );
    // }

    /**
     * Get all MY staked hd id
     */

    function myStakedHd() public view returns (uint256[] memory) {
        HigherDimensions x = HigherDimensions(HD_CONTRACT);
        uint256 hdCount = x.balanceOf(msg.sender);
        uint256[] memory tokenIds = new uint256[](hdCount);
        uint256 counter = 0;
        for (uint256 i = 0; i < hdCount; i++) {
            uint256 tokenId = x.tokenOfOwnerByIndex(msg.sender, i);
            StakedHdObj memory hd = stakedHd[tokenId];
            if (hd.kg > 0) {
                tokenIds[counter] = tokenId;
                counter++;
            }
        }
        return tokenIds;
    }

    /**
     * Calculates the TOTAL amount of wise that is claimable from ALL hds.
     */
    function myClaimableView() public view returns (uint256) {
        HigherDimensions x = HigherDimensions(HD_CONTRACT);
        uint256 cnt = x.balanceOf(msg.sender);
        require(cnt > 0, "NO HD");
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < cnt; i++) {
            uint256 tokenId = x.tokenOfOwnerByIndex(msg.sender, i);
            StakedHdObj memory hd = stakedHd[tokenId];
            // make sure that the token is staked
            if (hd.kg > 0) {
                uint256 claimable = claimableView(tokenId);
                if (claimable > 0) {
                    totalClaimable = totalClaimable + claimable;
                }
            }
        }
        return totalClaimable;
    }

    /**
     * Claims wise from the provided hds.
     */
    function _claimWise(uint256[] calldata tokenIds) internal {
        HigherDimensions x = HigherDimensions(HD_CONTRACT);
        uint256 totalClaimableWise = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(x.ownerOf(tokenIds[i]) == msg.sender, "NOT OWNER");
            StakedHdObj memory hd = stakedHd[tokenIds[i]];
            // we only care about hd that have been staked (i.e. kg > 0) ...
            if (hd.kg > 0) {
                uint256 claimableWise = claimableView(tokenIds[i]);
                if (claimableWise > 0) {
                    totalClaimableWise = totalClaimableWise + claimableWise;
                    // reset since, for the next calc...
                    hd.sinceTs = uint32(block.timestamp);
                    stakedHd[tokenIds[i]] = hd;
                }
            }
        }
        if (totalClaimableWise > 0) {
            _mint(msg.sender, totalClaimableWise);
            emit Minted(msg.sender, totalClaimableWise);
        }
    }

    /**
     * Claims wise from the provided hds.
     */
    function claimWise(uint256[] calldata tokenIds) external {
        _claimWise(tokenIds);
    }

    /**
     * Unstakes a hd. Why you'd call this, I have no idea.
     */
    function _unstake(uint256 tokenId) internal {
        HigherDimensions x = HigherDimensions(HD_CONTRACT);

        // verify user is the owner of the hd...
        require(x.ownerOf(tokenId) == msg.sender, "NOT OWNER");

        // update hd...
        StakedHdObj memory c = stakedHd[tokenId];
        if (c.kg > 0) {
            // update snapshot values...
            totalKg -= uint24(c.kg);
            totalStakedHd -= 1;

            c.kg = 0;
            stakedHd[tokenId] = c;

            // let ppl know!
            emit UnStaked(tokenId, block.timestamp);
        }
    }

    function _unstakeMultiple(uint256[] calldata tids) internal {
        for (uint256 i = 0; i < tids.length; i++) {
            _unstake(tids[i]);
        }
    }

    /**
     * Unstakes MULTIPLE hd. Why you'd call this, I have no idea.
     */
    function unstake(uint256[] calldata tids) external {
        _unstakeMultiple(tids);
    }

    /**
     * Unstakes MULTIPLE hd AND claims the wise.
     */
    function withdrawAllHdAndClaim(uint256[] calldata tids) external {
        _claimWise(tids);
        _unstakeMultiple(tids);
    }

    /**
     * Public : update the hd's KG level.
     */
     function levelUpHd(uint256 tid) external {
        StakedHdObj memory c = stakedHd[tid];
        require(c.kg > 0, "NOT STAKED");

        HigherDimensions x = HigherDimensions(HD_CONTRACT);
        // NOTE Does it matter if sender is not owner?
        // require(x.ownerOf(hdId) == msg.sender, "NOT OWNER");

        // check: hd has eaten enough...
        require(c.eatenAmount >= dmtLevelingRate(c.kg), "MORE FOOD REQD");
        // check: cooldown has passed...
        require(block.timestamp >= c.cooldownTs, "COOLDOWN NOT MET");

        // increase kg, reset eaten to 0, update next dmt level and cooldown time
        c.kg = c.kg + 100;
        c.eatenAmount = 0;
        c.cooldownTs = uint32(block.timestamp + cooldownRate(c.kg));
        stakedHd[tid] = c;

        // need to increase overall size
        totalKg += uint24(100);

        // and update the hd contract
        x.setKg(tid, c.kg);
    }

    /**
     * Internal: burns the given amount of wise from the wallet.
     */
    function _burnWise(address sender, uint256 wiseAmount) internal {
        // NOTE do we need to check this before burn?
        require(balanceOf(sender) >= wiseAmount, "NOT ENOUGH WISE");
        _burn(sender, wiseAmount);
        emit Burned(sender, wiseAmount);
    }

    /**
     * Burns the given amount of wise from the sender's wallet.
     */
    function burnWise(address sender, uint256 wiseAmount) external onlyAuthorized {
        _burnWise(sender, wiseAmount);
    }

    /**
     * Skips the "levelUp" cooling down period, in return for burning Wise.
     */
     function skipCoolingOff(uint256 tokenId, uint256 wiseAmt) external {
        StakedHdObj memory hd = stakedHd[tokenId];
        require(hd.kg != 0, "NOT STAKED");

        uint32 ts = uint32(block.timestamp);

        // NOTE Does it matter if sender is not owner?
        // HigherDimensions instance = HigherDimensions(HD_CONTRACT);
        // require(instance.ownerOf(hdId) == msg.sender, "NOT OWNER");

        // check: enough wise in wallet to pay
        uint256 walletBalance = balanceOf(msg.sender);
        require( walletBalance >= wiseAmt, "NOT ENOUGH WISE IN WALLET");

        // check: provided wise amount is enough to skip this level
        require(wiseAmt >= checkSkipCoolingOffAmt(hd.kg), "NOT ENOUGH WISE TO SKIP");

        // check: user hasn't skipped cooldown in last 24 hrs
        require((hd.lastSkippedTs + COOLDOWN_CD_IN_SECS) <= ts, "BLOCKED BY 24HR COOLDOWN");

        // burn wise
        _burnWise(msg.sender, wiseAmt);

        // disable cooldown
        hd.cooldownTs = ts;
        // track last time cooldown was skipped (i.e. now)
        hd.lastSkippedTs = ts;
        stakedHd[tokenId] = hd;
    }

    /**
     * Calculates the cost of skipping cooldown.
     */
    function checkSkipCoolingOffAmt(uint256 kg) public view returns (uint256) {
        // NOTE cannot assert KG is < 100... we can have large numbers!
        return ((kg / 100) * COOLDOWN_BASE_FACTOR);
    }

    /**
     * dmt dmting the hd
     */
    function dmtHd(uint256 tokenId, uint256 dmtAmount)
        external
        onlyAuthorized
    {
        StakedHdObj memory hd = stakedHd[tokenId];
        require(hd.kg > 0, "NOT STAKED");
        require(dmtAmount > 0, "NOTHING TO dmt");
        // update the block time as well as claimable
        hd.eatenAmount = uint48(dmtAmount / 1e18) + hd.eatenAmount;
        stakedHd[tokenId] = hd;
    }

    // NOTE What happens if we update the multiplier, and people have been staked for a year...?
    // We need to snapshot somehow... but we're physically unable to update 10k records!!!

    // Removed "updateBaseWise" - to make space

    // Removed "updateWisePerDayPerKg" - to make space

    // ADMIN: to update the cost of skipping cooldown
    function updateSkipCooldownValues(
        uint256 a, 
        uint256 b, 
        uint256 c,
        uint256 d,
        uint256 e
    ) external onlyOwner {
        COOLDOWN_BASE = a;
        COOLDOWN_BASE_FACTOR = b;
        COOLDOWN_CD_IN_SECS = c;
        BASE_HOLDER_WISE = d;
        WISE_PER_DAY_PER_KG = e;
    }

    // INTRA-CONTRACT: use this function to mint wise to users
    // this also get called by the dmt contract
    function mintWise(address sender, uint256 amount) external onlyAuthorized {
        _mint(sender, amount);
        emit Minted(sender, amount);
    }

    // ADMIN: drop wise to the given hd wallet owners (within the hdId range from->to).
    function airdropToExistingHolder(
        uint256 from,
        uint256 to,
        uint256 amountOfWise
    ) external onlyOwner {
        // mint 100 wise to every owners
        HigherDimensions instance = HigherDimensions(HD_CONTRACT);
        for (uint256 i = from; i <= to; i++) {
            address currentOwner = instance.ownerOf(i);
            if (currentOwner != address(0)) {
                _mint(currentOwner, amountOfWise * 1e18);
            }
        }
    }

    // ADMIN: Rebalance user wallet by minting wise (within the hdId range from->to).
    // NOTE: This is use when we need to update wise production
    function rebalanceWiseClaimableToUserWallet(uint256 from, uint256 to)
        external
        onlyOwner
    {
        HigherDimensions instance = HigherDimensions(HD_CONTRACT);
        for (uint256 i = from; i <= to; i++) {
            address currentOwner = instance.ownerOf(i);
            StakedHdObj memory hd = stakedHd[i];
            // we only care about hd that have been staked (i.e. kg > 0) ...
            if (hd.kg > 0) {
                _mint(currentOwner, claimableView(i));
                hd.sinceTs = uint32(block.timestamp);
                stakedHd[i] = hd;
            }
        }
    }
}
