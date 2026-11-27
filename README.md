by Dan

Here is the workflow as I now understand it:
1. Large M3U Archive — complete search results and pulled using archive.org scraper api

Each full search query produces its own source M3U containing all the content found by that search. These are the source inventories, not the curated library.


2. Master Library — your curated collections

Select content from one or more Large M3U Archive source M3Us, filter out unwanted items, and organize the remaining content into your own labelled collections.


3. Profiles — further-curated collections

Create profiles from Master Library collections. Give them custom labels and apply additional filters to remove anything you do not want. These become the prepared content sets for channel splitting.


4. Channel splitting — create channels from the collections

Split profile content into channels using genres, custom labels, decades, or custom decade groupings—for example, one channel containing both the 1980s and 1990s.


5. Channel playlists and master playlist

Produce the individual channel playlists and the combined master playlist M3U.


This also reveals an important issue in the current script: its existing Master Library creation code asks for Archive.org search queries, while its profile search code independently searches Archive.org. That does not yet implement the workflow you described. We will need to trace and correct that relationship rather than build more features on the wrong foundation.

One detail to clarify before we inspect the code: Can a single profile combine content from multiple labelled Master Library collections, or should each profile be based on just one Master Library collection?











Updated architecture
Large M3U Archive

Complete source M3Us from full search queries.
Programme Master Library

Curated programme collections
- Cartoons
- Sitcoms
- Christmas Specials
- Decades
- Custom labels


Commercial Master Library

Curated commercial collections
- Vintage Ads
- 1980s Commercials
- Food Advertisements
- Holiday Ads
- Custom labels



2 seperate master playlists. one for programs one for commercials

Programme Profiles

Combine programme collections and apply further filters.

Channel Splitting

Create channels using genres, decades, labels and custom groupings. with option for merging commercials profiles with programmes.

Channel Playlists

Select which commercial collections or profiles to merge into each channel.



One more design decision
Should commercials also have their own profiles, just like programmes?

My recommendation is yes. That would let you create commercial profiles combining multiple commercial collections, then choose which commercial profiles are inserted into which programme channels.
