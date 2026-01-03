SELECT
    episode.podcastID,
    podcast.title as feedTitle,
    episode.title,
    episode.userRecommendedTime,
    STRFTIME('%Y-%m-%d', CAST(episode.userRecommendedTime AS float),'unixepoch') AS userRecommendedTimeHuman,
    podcast.linkURL as feedLink,
    episode.linkURL as episodeURL,
    episode.enclosureURL as downloadURL,
    podcast.imageURL as feedArtworkURL
FROM OCEpisode AS episode
INNER JOIN OCPodcast AS podcast ON (episode.podcastID = podcast.id)
WHERE episode.userRecommendedTime IS NOT NULL
AND episode.userRecommendedTime > 0
ORDER BY episode.userRecommendedTime DESC;
