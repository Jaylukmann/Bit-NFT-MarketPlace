# Bit-NFT-MarketPlace

## This is an NFT market place where buyers can:
1. pay in dribs and drabs for any Non-fungible token of their choice in as much as it is listed on Bit-NFT-Market place.
2. On Bit-NFT-Marketplace,you as a seller can list your erc721 tokens for sale and a buyer can decide to buy it there and then, or on installment basis.
3. Sellers list their NFT by sending it to the Bit-NFT-Marketplace contract address inputting the NFT's address,its tokenId and the price you intend to sell it.
4. At the end of the duration of the sale which is 40 days(4 minutes for testing purpose),the seller gets his ether while the buyer gets his NFT.
5. However,if the buyer defaults by not paying up before the  expiry of the agreement,he forfeits 10% of the total ether sent(5% to the marketplace and 5% compensation to the seller) while the seller gets back his NFT.
6.  If the sale is an instant sale or instalment basis, the marketplace receive 5% of the NFT price...

##TESTING
The steps are :
1)Create 5 wallets with test ethers.
2)Deploy the smart contract with the first wallet(owner).
3)Use the second wallet to deploy an NFT contract.
4) Use the same second wallet to mint like 3 NFTs  to the same address.
5) Use the same second wallet to approve the smart Contract in 2 above.
6) Use the same second wallet to list the 3 NFTs calling listNFT function.
7) Use the 3rd wallet to call buyNow function on the first NFT.
8) Use the 4th wallet to call buyInBit  on the second NFT like three times till the price is complete to see if the NFT will be transfered to you and the ether to the seller(wallet two).
9)Lastly, use the 5th wallet to call buyInBit on the third NFT,wait till the time of the agreement elapse and call buyerClaim to claim back your fund. Then use wallet two(NFT owner) to call sellerClaim to claim back your NFT.


