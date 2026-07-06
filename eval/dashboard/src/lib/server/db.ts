import { PrismaClient } from '@prisma/client';
import { dev } from '$app/environment';

// Single Prisma client, reused across hot reloads in dev.
const globalForPrisma = globalThis as unknown as { prisma?: PrismaClient };

export const prisma = globalForPrisma.prisma ?? new PrismaClient();

if (dev) globalForPrisma.prisma = prisma;
