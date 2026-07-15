import { json } from '@sveltejs/kit';
import { prisma } from '$lib/server/db';
import type { RequestHandler } from './$types';

// GET /api/usage/<userId> → that user's daily usage rows, oldest→newest.
// Reads are public (same policy as the rest of the dashboard).
export const GET: RequestHandler = async ({ params }) => {
  const rows = await prisma.usageDaily.findMany({
    where: { userId: params.userId },
    orderBy: { day: 'asc' }
  });
  return json({ userId: params.userId, days: rows });
};
